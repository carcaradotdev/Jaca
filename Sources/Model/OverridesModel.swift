import Foundation
import Observation

/// **The single owner** of the response-override library: the rules, their order, the master
/// switch, live hit counts, and each transport's arming state.
///
/// Every screen reads this one object — the toolbar button, the popover, the editor, the row
/// badges and the detail banner — so there is never a second copy of "is this rule on?" to drift.
/// Views read its properties directly in `body`, so SwiftUI re-renders the moment anything
/// changes; nothing polls.
///
/// Rules are **global**, not per-session: a `NetworkSession` is rebuilt on tab open and on
/// relaunch-restore, and two tabs on one device must not disagree about what's mocked. Targeting
/// is a field on the rule (`scope`) instead.
@Observable
@MainActor
final class OverridesModel {

    // MARK: - Persisted state

    private(set) var rules: [OverrideRule]

    /// Applies every rule, or none. The recurring need is "let me see the real thing for a
    /// second", and hunting eight switches to do that is hostile.
    var masterEnabled: Bool {
        didSet {
            guard masterEnabled != oldValue else { return }
            FeatureFlags.overridesMasterEnabled = masterEnabled
            republish()
        }
    }

    // MARK: - Runtime-only state (never persisted)

    private(set) var hitCounts: [UUID: Int] = [:]
    private(set) var lastHitAt: [UUID: Date] = [:]
    /// Arming state per **device + package**. Keying by bare package cross-wired two devices
    /// running the same app: the second registration replaced the first, so the first tab's
    /// host-set updates went nowhere and both showed the same status.
    private(set) var armings: [InterceptTarget: AgentDivertCoordinator.State] = [:]
    /// Which transaction was answered/rewritten by which rule — drives the row badges.
    private(set) var appliedRuleByTransaction: [UUID: UUID] = [:]
    /// Reclaimed tunnels from a previous run, surfaced once so cleanup is never silent.
    private(set) var reclaimedTunnelCount = 0

    private let resolver = OverrideResolver()
    private var coordinators: [InterceptTarget: AgentDivertCoordinator] = [:]

    // MARK: - Init

    init() {
        // Loaded synchronously so the very first frame already has the user's rules and the
        // popover never flashes empty — the cache-first rule.
        self.rules = OverrideRuleStore.load()
        self.masterEnabled = FeatureFlags.overridesMasterEnabled
        JacaLog.info("override",
            "loaded \(rules.count) rule(s) from \(OverrideRuleStore.rulesURL.path); master=\(masterEnabled)")
        republish()
    }

    /// Removes tunnels stranded by a previous run that died without cleaning up.
    func reconcileOrphanedTunnels() {
        let count = AdbTunnelCleanup.reconcileOrphansFromPreviousRuns()
        if count > 0 { reclaimedTunnelCount = count }
    }

    // MARK: - Services handed to transports

    /// What a capture source needs to participate. Transports get a resolver and a reporter —
    /// never this model, never the rule list, never SwiftUI.
    func services() -> InterceptServices {
        InterceptServices(
            resolver: resolver,
            reporter: Reporter { [weak self] requestID, ruleID in
                Task { @MainActor in self?.recordHit(requestID: requestID, ruleID: ruleID) }
            },
            onArmingChange: { [weak self] target, state in
                Task { @MainActor in self?.armings[target] = state }
            },
            onRegisterCoordinator: { [weak self] target, coordinator in
                Task { @MainActor in
                    guard let self else { return }
                    if let coordinator {
                        self.coordinators[target] = coordinator
                        coordinator.updateHosts(self.divertHosts(for: target))
                    } else {
                        self.coordinators.removeValue(forKey: target)
                        self.armings.removeValue(forKey: target)
                    }
                }
            }
        )
    }

    /// A `Sendable` shim so the reporter can be called from a NIO event loop.
    private struct Reporter: InterceptReporting {
        let onApplied: @Sendable (UUID, UUID?) -> Void
        init(_ onApplied: @escaping @Sendable (UUID, UUID?) -> Void) { self.onApplied = onApplied }
        func report(requestID: UUID, appliedRuleID: UUID?, skipped: InterceptSkipReason?) {
            onApplied(requestID, appliedRuleID)
        }
    }

    // MARK: - Mutations

    /// Adds a rule.
    ///
    /// New rules are enabled by default — but that default lives in `OverrideRule.enabled`, not
    /// here. Forcing it at this point would silently re-enable a rule the user had just switched
    /// off in the editor before saving.
    func add(_ rule: OverrideRule) {
        var newRule = rule
        if newRule.divertHosts.isEmpty {
            newRule.divertHosts = OverrideCompiler.derivedDivertHosts(for: newRule.matcher)
        }
        rules.append(newRule)
        persistAndRepublish()
    }

    func update(_ rule: OverrideRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        persistAndRepublish()
    }

    /// Saves a rule whether or not it already exists.
    ///
    /// The editor sheet calls this instead of choosing between `add` and `update` itself: getting
    /// that choice wrong silently discarded the rule (`update` no-ops on an unknown id), which is
    /// the worst possible failure for a "save" button. Here an unknown id simply means "new".
    func save(_ rule: OverrideRule) {
        if rules.contains(where: { $0.id == rule.id }) { update(rule) } else { add(rule) }
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        hitCounts.removeValue(forKey: id)
        lastHitAt.removeValue(forKey: id)
        persistAndRepublish()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = enabled
        persistAndRepublish()
    }

    func duplicate(_ id: UUID) {
        guard let source = rules.first(where: { $0.id == id }) else { return }
        let copy = OverrideRule(id: UUID(),
                                name: source.name.isEmpty ? "Copy" : "\(source.name) copy",
                                enabled: true, matcher: source.matcher, scope: source.scope,
                                action: source.action, delayMillis: source.delayMillis,
                                divertHosts: source.divertHosts)
        rules.append(copy)
        persistAndRepublish()
    }

    /// Precedence is list order, so moving a rule up is how the user resolves shadowing.
    func move(_ id: UUID, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        rules.swapAt(index, target)
        persistAndRepublish()
    }

    // MARK: - Derived state the UI renders

    var enabledCount: Int { rules.filter(\.enabled).count }

    /// The compiled snapshot, for match previews and shadow detection in the editor.
    var compiled: OverrideRuleSet { resolver.current }

    func hitCount(for id: UUID) -> Int { hitCounts[id] ?? 0 }

    func diagnostic(for id: UUID) -> String? { resolver.current.diagnostics[id] }

    /// The rule that produced this transaction's response, if any.
    ///
    /// Reads the stamp the transaction itself carries. The old id-keyed map could never match:
    /// `OverrideServer` mints a fresh `InterceptedRequest.id` that no captured row shares.
    func appliedRule(for txn: NetworkTransaction) -> OverrideRule? {
        guard let ruleID = txn.overriddenByRuleID else { return nil }
        return rules.first { $0.id == ruleID }
    }

    /// Rules that would match this request but can't run on the given transport — the "matches
    /// but can't run here" state, computed by the same clamp the runtime uses.
    func blockedReason(forURL url: String, method: String,
                       transport: InterceptTransportID,
                       capabilities: InterceptCapabilities) -> InterceptSkipReason? {
        guard let facts = OverrideMatching.facts(url: url) else { return nil }
        guard let matched = resolver.current.firstMatch(facts: facts, method: method,
                                                        deviceID: nil, appID: nil) else { return nil }
        let (_, skip) = OverrideMatching.decide(matched, transport: transport,
                                                capabilities: capabilities,
                                                masterEnabled: masterEnabled)
        return skip
    }

    /// Whether an enabled rule matches this request at all (regardless of transport).
    func matchingRule(forURL url: String, method: String) -> OverrideRule? {
        guard let facts = OverrideMatching.facts(url: url) else { return nil }
        return resolver.current.firstMatch(facts: facts, method: method,
                                           deviceID: nil, appID: nil)?.rule
    }

    func arming(for target: InterceptTarget) -> AgentDivertCoordinator.State {
        armings[target] ?? .idle
    }

    // MARK: - Seeding from a captured request

    /// Builds a rule pre-filled from a captured transaction — the right-click path.
    ///
    /// The rule takes its **own copy** of the body: `NetworkBodyCache` clears itself on every
    /// launch, so a rule that referred back to capture would silently lose its payload.
    func seed(from txn: NetworkTransaction, session: NetworkSession) async -> OverrideRule {
        let bodies = await session.bodies(for: txn.id)
        let responseBody = bodies.resp ?? Data()

        var rule = OverrideRule()
        rule.name = OverrideSeeding.name(for: txn)
        rule.matcher = OverrideMatcher(pattern: OverrideSeeding.pattern(for: txn),
                                       kind: .glob,
                                       methods: [txn.method.uppercased()])
        rule.divertHosts = OverrideCompiler.derivedDivertHosts(for: rule.matcher)

        let pretty = OverrideSeeding.prettyPrinted(responseBody, contentType: txn.responseContentType)
        rule.action = .respond(OverrideResponseSpec(
            statusCode: txn.statusCode ?? 200,
            headers: OverrideSeeding.headers(txn.responseHeaders),
            body: OverrideRuleStore.makeBodyRef(pretty)
        ))
        return rule
    }

    // MARK: - Internals

    /// Hosts to route for one target. Passing the real `deviceID` matters: a device-scoped rule
    /// contributed no hosts while this was hard-coded nil, so it could never fire.
    private func divertHosts(for target: InterceptTarget) -> Set<String> {
        resolver.current.divertHosts(deviceID: target.deviceID, appID: target.package)
    }

    private func recordHit(requestID: UUID, ruleID: UUID?) {
        guard let ruleID else { return }
        JacaLog.info("override", "rule applied: \(rules.first { $0.id == ruleID }?.displayName ?? ruleID.uuidString)")
        hitCounts[ruleID, default: 0] += 1
        lastHitAt[ruleID] = Date()
        appliedRuleByTransaction[requestID] = ruleID
    }

    private func persistAndRepublish() {
        let ok = OverrideRuleStore.save(rules)
        JacaLog.info("override", "saved \(rules.count) rule(s) -> \(ok ? "ok" : "FAILED")")
        republish()
    }

    /// Recompiles and pushes the snapshot to the resolver and to every armed transport. This is
    /// what makes an edit apply on the app's **next request** with no re-attach.
    private func republish() {
        resolver.publish(OverrideCompiler.compile(rules, masterEnabled: masterEnabled))
        for (target, coordinator) in coordinators {
            coordinator.updateHosts(divertHosts(for: target))
        }
    }
}
