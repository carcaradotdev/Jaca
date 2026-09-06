import Foundation
import Observation

/// **The single owner** of the response-override library: the rules, their order, the master
/// switch, live hit counts, and each transport's arming state. Every override surface reads this
/// one object, so there is never a second copy of "is this rule on?" to drift.
///
/// Rules are **global**, not per-session: sessions are rebuilt on tab open and relaunch-restore,
/// and two tabs on one device must not disagree about what's mocked. Targeting is `scope`.
@Observable
@MainActor
final class OverridesModel {

    // MARK: - Persisted state

    private(set) var rules: [OverrideRule]

    /// Applies every rule, or none — for "let me see the real thing for a second".
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
    /// Arming state per **device + package**: keying by bare package cross-wired two devices
    /// running the same app, so one tab's host-set updates went nowhere.
    private(set) var armings: [InterceptTarget: InterceptArmingState] = [:]
    /// Reclaimed tunnels from a previous run, surfaced once so cleanup is never silent.
    private(set) var reclaimedTunnelCount = 0

    /// The last thing overrides actually **did**, timestamped — the popover's answer to "is
    /// anything happening?". Lives here rather than being tailed out of the log file in `body`:
    /// that was a synchronous read on the main thread, and not observable, so a rule firing
    /// changed nothing on screen.
    private(set) var lastActivity: String?

    private let resolver = OverrideResolver()
    private var coordinators: [InterceptTarget: DivertCoordinator] = [:]

    // MARK: - Init

    init() {
        // Synchronous so the first frame already has the user's rules — the cache-first rule.
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

    /// What a capture source needs to participate: a resolver and a reporter, never this model.
    func services() -> InterceptServices {
        InterceptServices(
            resolver: resolver,
            reporter: Reporter { [weak self] _, ruleID in
                Task { @MainActor in self?.recordHit(ruleID: ruleID) }
            },
            onArmingChange: { [weak self] target, coordinator, state in
                Task { @MainActor in
                    guard let self else { return }
                    // Same target-reuse hazard as `onDeregisterCoordinator`: on a restart the old
                    // teardown publishes `.idle` ~300 ms after the new coordinator published
                    // `.active`, and that stale value would win *permanently* — `state`'s `didSet`
                    // only fires on a change, so the live coordinator never re-publishes.
                    if let coordinator, self.coordinators[target] !== coordinator { return }
                    self.armings[target] = state
                }
            },
            onRegisterCoordinator: { [weak self] target, coordinator in
                Task { @MainActor in
                    guard let self else { return }
                    // Registration happens in the controller's `init`, before the launcher claim,
                    // so a second tab on the same simulator + app registers over the first and
                    // only then finds the app claimed. Evicting there orphaned the live tab's
                    // coordinator for good. A *stopped* one is the ordinary restart: replace it.
                    if let existing = self.coordinators[target],
                       existing !== coordinator, !existing.isStopped { return }
                    self.coordinators[target] = coordinator
                    coordinator.updateHosts(self.divertHosts(for: target))
                }
            },
            onDeregisterCoordinator: { [weak self] target, coordinator in
                Task { @MainActor in
                    guard let self else { return }
                    // A restart reuses the target, so a late teardown must not evict its
                    // replacement.
                    guard self.coordinators[target] === coordinator else { return }
                    self.coordinators.removeValue(forKey: target)
                    self.armings.removeValue(forKey: target)
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

    /// Adds a rule. The enabled-by-default lives in `OverrideRule.enabled`, not here — forcing
    /// it would re-enable a rule the user switched off in the editor before saving.
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

    /// Saves a rule whether or not it already exists, so the editor never has to choose between
    /// `add` and `update` — getting that wrong silently discarded the rule.
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

    /// The rule that produced this response, read from the stamp the transaction carries — an
    /// id-keyed map can't work, since `OverrideServer` mints ids no captured row shares.
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

    func arming(for target: InterceptTarget) -> InterceptArmingState {
        armings[target] ?? .idle
    }

    // MARK: - Seeding from a captured request

    /// Builds a rule pre-filled from a captured transaction — the right-click path. Takes its
    /// **own copy** of the body: `NetworkBodyCache` clears on launch, so a reference would lose
    /// its payload.
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

    /// Hosts to route for one target. The real `deviceID` matters: with it hard-coded nil, a
    /// device-scoped rule contributed no hosts and could never fire.
    private func divertHosts(for target: InterceptTarget) -> Set<String> {
        resolver.current.divertHosts(deviceID: target.deviceID, appID: target.package)
    }

    private func recordHit(ruleID: UUID?) {
        guard let ruleID else { return }
        // `debug`, not `info`: one per overridden request, and `JacaLog.append` blocks on the
        // filesystem from the main actor. `lastActivity` below is the user-facing one.
        JacaLog.debug("override", "rule applied: \(rules.first { $0.id == ruleID }?.displayName ?? ruleID.uuidString)")
        hitCounts[ruleID, default: 0] += 1
        let now = Date()
        lastHitAt[ruleID] = now
        let name = rules.first { $0.id == ruleID }?.displayName ?? "a rule"
        lastActivity = "\(now.formatted(date: .omitted, time: .standard)) · applied \(name)"
    }

    private func persistAndRepublish() {
        let ok = OverrideRuleStore.save(rules)
        JacaLog.info("override", "saved \(rules.count) rule(s) -> \(ok ? "ok" : "FAILED")")
        republish()
    }

    /// Recompiles and pushes to the resolver and every armed transport — what makes an edit
    /// apply on the app's next request with no re-attach.
    private func republish() {
        resolver.publish(OverrideCompiler.compile(rules, masterEnabled: masterEnabled))
        for (target, coordinator) in coordinators {
            coordinator.updateHosts(divertHosts(for: target))
        }
    }
}
