import Foundation
import Observation

/// **The single owner** of the response-override library in the app: the rules, their order, the
/// master switch, live hit counts, and each transport's arming state. Every override surface reads
/// this one object, so there is never a second copy of "is this rule on?" to drift.
///
/// The runtime (resolver, coordinators, hit reporting) is `OverridesEngine`, which must live in the
/// process that runs the capture: in-process here, or in `jacad` when network capture runs in the
/// daemon — then this model mirrors the daemon's retained `overrides.state`, and compiles the
/// mirrored rules locally for the editor's match previews.
@Observable
@MainActor
final class OverridesModel {

    // MARK: - State (mirrored from the engine)

    /// In display order, which is precedence (`OverrideGrouping`).
    private(set) var rules: [OverrideRule] = []
    private(set) var groups: [OverrideGroup] = []

    /// Applies every rule, or none — for "let me see the real thing for a second".
    var masterEnabled: Bool = true {
        didSet {
            guard masterEnabled != oldValue, !applyingState else { return }
            let enabled = masterEnabled
            send("overrides.setMaster", OverridesArea.MasterParams(enabled: enabled)) { $0.setMasterEnabled(enabled) }
        }
    }

    private(set) var hitCounts: [UUID: Int] = [:]
    private(set) var lastHitAt: [UUID: Date] = [:]
    /// Arming state per **device + package**.
    private(set) var armings: [InterceptTarget: InterceptArmingState] = [:]
    /// Reclaimed tunnels from a previous run, surfaced once so cleanup is never silent.
    private(set) var reclaimedTunnelCount = 0
    /// The last thing overrides actually **did**, timestamped.
    private(set) var lastActivity: String?

    /// The compiled snapshot, for match previews and shadow detection in the editor.
    private(set) var compiled = OverrideRuleSet.empty

    /// Groups the list shows open. View state for this run only: kept here so a group stays
    /// open when the popover closes and opens again, and never saved.
    var expandedGroups: Set<UUID> = []

    // MARK: - Plumbing

    private let daemon: DaemonConnector
    /// Whether the runtime lives in `jacad` (network capture runs there). Follows
    /// `DaemonConnector.networkRunsInDaemon` only, which the inspection mode doesn't change.
    private(set) var usesDaemon: Bool
    private var localEngine: OverridesEngine?
    private var daemonWatch: Task<Void, Never>?
    private let commands = DaemonCommandQueue()
    private var applyingState = false
    private var compiledOnce = false

    init(daemon: DaemonConnector? = nil, inDaemon: Bool? = nil) {
        let daemon = daemon ?? .shared
        self.daemon = daemon
        usesDaemon = inDaemon ?? daemon.networkRunsInDaemon()
        if usesDaemon { watchDaemon() } else { startLocalEngine() }
    }

    /// Moves the runtime between this process and `jacad`. The app no longer calls it, because
    /// `networkRunsInDaemon` is fixed for the run; the tests use it to check a handover. The side
    /// giving it up stops publishing; the daemon re-reads the library when it takes over, since
    /// the app may have edited it meanwhile.
    func setRuntime(inDaemon: Bool) {
        guard inDaemon != usesDaemon else { return }
        usesDaemon = inDaemon
        if inDaemon {
            if let local = localEngine {
                local.onChange = nil
                localEngine = nil
            }
            watchDaemon()
        } else {
            daemonWatch?.cancel()
            daemonWatch = nil
            // After any edit still queued for the daemon, so the local engine reads it from disk.
            // Skipped if the runtime moved back to the daemon meanwhile.
            commands.enqueue { [weak self] in
                guard let self, !self.usesDaemon else { return }
                self.startLocalEngine()
            }
        }
    }

    private func watchDaemon() {
        // First frame from disk (read-only); the daemon's retained state follows.
        var initial = OverridesState()
        initial.groups = OverrideRuleStore.loadGroups()
        initial.rules = OverrideGrouping.normalized(OverrideRuleStore.load(), groups: initial.groups)
        initial.masterEnabled = FeatureFlags.overridesMasterEnabled
        apply(initial)
        // On every (re)connection: the app may have edited the library in-process meanwhile (the
        // runtime was here, or the daemon was unreachable), and the daemon's retained state
        // predates that.
        daemonWatch = daemon.watch([OverridesArea.stateTopic], onSubscribed: { [daemon] in
            let _: RPCEmpty? = await daemon.call("overrides.reload")
        }) { [weak self] event in
            guard let self, self.usesDaemon, let state = try? event.decode(OverridesState.self) else { return }
            self.apply(state)
        }
    }

    @discardableResult
    private func startLocalEngine() -> OverridesEngine {
        let existing = localEngine
        let engine = existing ?? OverridesEngine()
        localEngine = engine
        // Mirrored only while it owns the runtime; `services()` in daemon mode must not let it
        // overwrite the state mirrored from jacad. One created in daemon mode is wired (and
        // re-read) when the runtime moves here.
        if !usesDaemon, engine.onChange == nil {
            if existing != nil { engine.reload() }
            engine.onChange = { [weak self] in self?.apply($0) }
            apply(engine.state)
        }
        return engine
    }

    private func apply(_ state: OverridesState) {
        applyingState = true
        defer { applyingState = false }
        let rulesChanged = rules != state.rules || groups != state.groups || masterEnabled != state.masterEnabled
        rules = state.rules
        groups = state.groups
        masterEnabled = state.masterEnabled
        hitCounts = Dictionary(uniqueKeysWithValues: state.hitCounts.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        lastHitAt = Dictionary(uniqueKeysWithValues: state.lastHitAt.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        armings = Dictionary(state.armings.map { ($0.target, $0.state) }, uniquingKeysWith: { _, last in last })
        reclaimedTunnelCount = state.reclaimedTunnelCount
        lastActivity = state.lastActivity
        // Compiled here from the rules (a pure function) rather than read from the engine: the
        // engine reports a change before it republishes its resolver.
        if rulesChanged || !compiledOnce {
            compiled = OverrideCompiler.compile(rules, masterEnabled: masterEnabled, groups: groups)
            compiledOnce = true
        }
    }

    /// Runs a mutation on the in-process engine, or sends it to the daemon's (in order). When the
    /// daemon can't be reached the edit is applied in-process instead of being lost; both engines
    /// re-read `rules.json` before mutating, so neither later writes a stale list over it.
    private func send<P: Encodable & Sendable>(_ method: String, _ params: P,
                                                local: @escaping (OverridesEngine) -> Void) {
        guard usesDaemon else {
            // Just switched from the daemon: let edits already queued for it land first.
            if localEngine == nil, commands.hasPending {
                commands.enqueue { [weak self] in
                    guard let self else { return }
                    local(self.startLocalEngine())
                }
            } else {
                local(startLocalEngine())
            }
            return
        }
        commands.enqueue { [weak self, daemon] in
            do {
                if try await daemon.request(method, params, as: RPCEmpty.self) != nil { return }
            } catch {
                DaemonLog.error("\(method) failed in jacad: \(error.localizedDescription)")
                // Undo the optimistic master switch (and anything else) with the daemon's state.
                if let state = try? await daemon.request("overrides.state", RPCEmpty(), as: OverridesState.self) {
                    self?.apply(state)
                }
                return
            }
            guard let self else { return }
            DaemonLog.info("\(method): jacad unreachable, applying in-process")
            local(OverridesEngine())
            // The daemon re-reads the file on its next mutation; this mirror re-reads it now.
            var state = OverridesState()
            state.groups = OverrideRuleStore.loadGroups()
            state.rules = OverrideGrouping.normalized(OverrideRuleStore.load(), groups: state.groups)
            state.masterEnabled = FeatureFlags.overridesMasterEnabled
            self.apply(state)
        }
    }

    /// Removes tunnels stranded by a previous run that died without cleaning up. In daemon mode
    /// the daemon does this when it starts.
    func reconcileOrphanedTunnels() {
        guard !usesDaemon else { return }
        startLocalEngine().reconcileOrphanedTunnels()
    }

    // MARK: - Services handed to transports

    /// What an in-process capture source needs to participate. Only meaningful when the runtime
    /// is in this process; the daemon hands its own engine's services to its captures.
    func services() -> InterceptServices {
        startLocalEngine().services()
    }

    /// Services for an in-process capture, or nil when the runtime lives in `jacad` (a tab that
    /// captures in-process there — companion capture — runs without overrides).
    var localServices: InterceptServices? {
        usesDaemon ? nil : services()
    }

    // MARK: - Mutations

    func add(_ rule: OverrideRule) { save(rule) }
    func update(_ rule: OverrideRule) {
        guard rules.contains(where: { $0.id == rule.id }) else { return }
        save(rule)
    }

    /// Saves a rule whether or not it already exists, so the editor never has to choose between
    /// `add` and `update` — getting that wrong silently discarded the rule.
    func save(_ rule: OverrideRule) {
        send("overrides.save", OverridesArea.RuleParams(rule: rule)) { $0.save(rule) }
    }

    func remove(_ id: UUID) {
        send("overrides.remove", OverridesArea.IDParams(id: id)) { $0.remove(id) }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        send("overrides.setEnabled", OverridesArea.EnabledParams(id: id, enabled: enabled)) { $0.setEnabled(enabled, for: id) }
    }

    func duplicate(_ id: UUID) {
        send("overrides.duplicate", OverridesArea.IDParams(id: id)) { $0.duplicate(id) }
    }

    /// Precedence is list order, so moving a rule up is how the user resolves shadowing.
    func move(_ id: UUID, by offset: Int) {
        send("overrides.move", OverridesArea.MoveParams(id: id, offset: offset)) { $0.move(id, by: offset) }
    }

    // MARK: - Groups

    /// Adds a group at the end of the list, or saves a rename or its switch.
    func saveGroup(_ group: OverrideGroup) {
        send("overrides.saveGroup", OverridesArea.GroupParams(group: group)) { $0.saveGroup(group) }
    }

    /// Deletes a group. Its rules stay, in no group.
    func removeGroup(_ id: UUID) {
        send("overrides.removeGroup", OverridesArea.IDParams(id: id)) { $0.removeGroup(id) }
    }

    func setEnabled(_ enabled: Bool, forGroup id: UUID) {
        guard var group = groups.first(where: { $0.id == id }), group.enabled != enabled else { return }
        group.enabled = enabled
        saveGroup(group)
    }

    func moveGroup(_ id: UUID, by offset: Int) {
        send("overrides.moveGroup", OverridesArea.MoveParams(id: id, offset: offset)) { $0.moveGroup(id, by: offset) }
    }

    /// Puts a rule at the end of a group, or (nil) in no group.
    func setGroup(_ groupID: UUID?, for id: UUID) {
        send("overrides.setGroup", OverridesArea.SetGroupParams(id: id, group: groupID)) { $0.setGroup(groupID, for: id) }
    }

    // MARK: - Derived state the UI renders

    /// The groups and their rules, then the rules in no group: what the list shows.
    var sections: [OverrideGrouping.Section] { OverrideGrouping.sections(rules, groups: groups) }

    /// Whether the rule applies, master switch aside: it is on, and so is its group.
    func isActive(_ rule: OverrideRule) -> Bool { OverrideGrouping.isActive(rule, groups: groups) }

    var enabledCount: Int { rules.filter(isActive).count }

    func hitCount(for id: UUID) -> Int { hitCounts[id] ?? 0 }

    func diagnostic(for id: UUID) -> String? { compiled.diagnostics[id] }

    /// The rule that produced this response, read from the stamp the transaction carries.
    func appliedRule(for txn: NetworkTransaction) -> OverrideRule? {
        guard let ruleID = txn.overriddenByRuleID else { return nil }
        return rules.first { $0.id == ruleID }
    }

    /// Rules that would match this request but can't run on the given transport — the "matches
    /// but can't run here" state, computed by the same clamp the runtime uses.
    func blockedReason(forURL url: String, method: String,
                       transport: InterceptTransportID, deviceID: String? = nil,
                       capabilities: InterceptCapabilities) -> InterceptSkipReason? {
        guard let facts = OverrideMatching.facts(url: url) else { return nil }
        guard let matched = compiled.firstMatch(
            facts: facts, method: method, deviceID: nil, appID: nil,
            transport: Self.hostFilterTransport(transport, deviceID: deviceID)) else { return nil }
        let (_, skip) = OverrideMatching.decide(matched, transport: transport,
                                                capabilities: capabilities,
                                                masterEnabled: masterEnabled)
        return skip
    }

    /// Whether an enabled rule matches this request. With a `transport`, the rule must also
    /// pass the routed-host filter the runtime applies there (`OverrideHostFilter`), so the row
    /// never claims a rule that the MITM proxy would skip.
    func matchingRule(forURL url: String, method: String, transport: InterceptTransportID? = nil,
                      deviceID: String? = nil) -> OverrideRule? {
        guard let facts = OverrideMatching.facts(url: url) else { return nil }
        return compiled.firstMatch(facts: facts, method: method, deviceID: nil, appID: nil,
                                   transport: Self.hostFilterTransport(transport, deviceID: deviceID))?.rule
    }

    /// The transport to hand `firstMatch` so it filters by host as the runtime does for
    /// `deviceID`. The rules are matched without a device scope here, so the device only
    /// decides whether the filter runs (This Mac's browser capture has none).
    nonisolated static func hostFilterTransport(_ transport: InterceptTransportID?, deviceID: String?) -> InterceptTransportID? {
        guard let transport else { return nil }
        return OverrideHostFilter.applies(transport: transport, deviceID: deviceID) ? transport : nil
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
        return OverrideSeeding.rule(for: txn, responseBody: bodies.resp ?? Data())
    }
}
