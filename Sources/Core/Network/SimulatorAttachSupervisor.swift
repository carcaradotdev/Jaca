import Foundation

/// Notices that the target app is running **without** the agent in it, and reports or repairs it.
///
/// `DYLD_INSERT_LIBRARIES` only applies to the process `simctl` spawned, so an app the *user*
/// quits and reopens comes back with nothing injected — capture and overrides stop with the tab
/// still claiming to capture, the "armed but silently doing nothing" state this layer exists to
/// prevent.
///
/// **Event-driven, and free while healthy**: it wakes on the channel's connect/disconnect
/// callbacks and one post-launch check, and spawns no process while the agent is connected.
/// Probing stays bounded to the unhealthy window — immediately, then 2 s → 4 s → 8 s → 15 s.
///
/// Owns the *decision* (via the pure `SimulatorReattachPolicy`) and the announcement, but not the
/// relaunch: the claim, injection environment and load check belong to the controller.
final class SimulatorAttachSupervisor: @unchecked Sendable {

    private let key: SimulatorAppLauncher.Key
    private let grace: Duration
    /// Read per decision, not captured once: the preference can change mid-capture.
    private let autoReattach: @Sendable () -> Bool
    private let launcher: SimulatorAppLauncher
    private let probe: @Sendable (SimulatorAppLauncher.Key) async -> SimulatorProcesses.Presence
    private let relaunch: @Sendable () async -> Void
    private let onPresence: @Sendable (SimulatorProcesses.Presence, Bool) -> Void
    private let onStatus: @Sendable (String) -> Void

    /// How long the agent gets to dial back before we look. Matches the controller's "launched
    /// but never loaded" diagnostic, so the two don't contradict each other for seconds.
    private let loadCheck: Duration

    /// A dylib that can't load makes every relaunch produce the same "running, no agent" answer,
    /// so an unbudgeted automatic mode would restart the user's app forever. After this many
    /// consecutive automatic relaunches with no connection in between, it falls back to asking.
    private let autoRelaunchBudget = 2

    private let lock = NSLock()
    private var connected = false
    private var stopped = false
    private var probeTask: Task<Void, Never>?
    /// Reserves the probe loop *before* the `Task` exists. `probeTask == nil` couldn't: the lock
    /// is released to build the `Task`, so an `agentConnected()` in that window cleared an empty
    /// slot and the finished task was stored afterwards — leaving `probeTask` permanently
    /// non-nil and detach detection dead for the life of the tab.
    private var probing = false
    /// Distinguishes "the loop that just exited" from a newer one that has since taken the slot.
    private var probeGeneration = 0
    private var loadCheckTask: Task<Void, Never>?
    private var autoRelaunchesUsed = 0
    /// Suppresses re-announcing the same unhealthy answer at the 15 s ceiling — it's on screen.
    private var lastAnnounced: SimulatorProcesses.Presence?

    init(key: SimulatorAppLauncher.Key,
         grace: Duration = .seconds(8),
         loadCheck: Duration = .seconds(6),
         autoReattach: @escaping @Sendable () -> Bool = { FeatureFlags.simulatorAutoReattachEnabled },
         launcher: SimulatorAppLauncher = .shared,
         probe: @escaping @Sendable (SimulatorAppLauncher.Key) async -> SimulatorProcesses.Presence
             = { await SimulatorProcesses.probe(udid: $0.udid, bundleID: $0.bundleID) },
         relaunch: @escaping @Sendable () async -> Void,
         onPresence: @escaping @Sendable (SimulatorProcesses.Presence, Bool) -> Void,
         onStatus: @escaping @Sendable (String) -> Void) {
        self.key = key
        self.grace = grace
        self.loadCheck = loadCheck
        self.autoReattach = autoReattach
        self.launcher = launcher
        self.probe = probe
        self.relaunch = relaunch
        self.onPresence = onPresence
        self.onStatus = onStatus
    }

    // MARK: - Events

    /// The agent's first bytes arrived, so it loaded in-process. Everything this class costs is
    /// cancelled here: a healthy session pays nothing.
    func agentConnected() {
        let toCancel: [Task<Void, Never>] = withLock {
            connected = true
            autoRelaunchesUsed = 0
            lastAnnounced = nil
            let tasks = [probeTask, loadCheckTask].compactMap { $0 }
            probeTask = nil
            probing = false
            loadCheckTask = nil
            return tasks
        }
        toCancel.forEach { $0.cancel() }
    }

    /// The agent's socket closed — the app exited, or was replaced by an uninstrumented process.
    /// Only the simulator can say which, so this is the one moment probing earns a spawn.
    func agentDisconnected() {
        withLock { connected = false }
        startProbing()
    }

    /// A launch went out. Starts the single post-launch check: if the agent hasn't dialled back
    /// by then it never will, and the reason is worth one probe to establish.
    func noteLaunched() {
        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.loadCheck)
            guard !Task.isCancelled, !self.isConnected, !self.isStopped else { return }
            self.startProbing()
        }
        let previous = withLock {
            defer { loadCheckTask = task }
            return loadCheckTask
        }
        previous?.cancel()
    }

    func stop() {
        let toCancel: [Task<Void, Never>] = withLock {
            stopped = true
            let tasks = [probeTask, loadCheckTask].compactMap { $0 }
            probeTask = nil
            probing = false
            loadCheckTask = nil
            return tasks
        }
        toCancel.forEach { $0.cancel() }
    }

    /// Relaunch with the agent injected — from the banner (explicit consent) or the automatic
    /// path, which announces itself here so a self-restarting app always explains why.
    func relaunchNow() async {
        guard !isStopped else { return }
        onStatus("network agent: relaunching \(key.bundleID) to re-attach…")
        await relaunch()
    }

    // MARK: - Probing (only while unhealthy)

    private func startProbing() {
        let generation: Int? = withLock {
            guard !stopped, !probing else { return nil }
            probing = true
            probeGeneration += 1
            return probeGeneration
        }
        guard let generation else { return }

        let task = Task { [weak self] in
            // However this loop leaves, it must hand the slot back or nothing can probe again.
            defer { self?.probingEnded(generation: generation) }
            // Immediate: the tab has just stopped producing rows, and two more seconds of
            // "capturing…" is two seconds of a lie.
            var delay: Duration = .zero
            var backoff: Duration = .seconds(2)
            while !Task.isCancelled {
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self, !self.isConnected, !self.isStopped else { return }
                await self.probeOnce()
                delay = backoff
                // Ceiling, not "give up": the answer can still change with no event to observe.
                backoff = min(backoff * 2, .seconds(15))
            }
        }
        // Generation-checked: `startProbing` is reachable concurrently (the reader thread's
        // `agentDisconnected()`, the grace Task in `noteLaunched()`), and a run preempted between
        // creating its Task and installing it would otherwise cancel a newer live loop and leave
        // `probing` stuck true for the life of the tab.
        var previous: Task<Void, Never>?
        let installed: Bool = withLock {
            guard probeGeneration == generation else { return false }
            previous = probeTask
            probeTask = task
            return true
        }
        guard installed else { return task.cancel() }
        previous?.cancel()
    }

    private func probingEnded(generation: Int) {
        withLock {
            // A newer run already owns the slot — leave it alone.
            guard probeGeneration == generation else { return }
            probing = false
            probeTask = nil
        }
    }

    private func probeOnce() async {
        let presence = await probe(key)
        guard !isConnected, !isStopped else { return }

        let since = await launcher.lastLaunch(key).map { Duration.seconds(-$0.timeIntervalSinceNow) }
        let decision = SimulatorReattachPolicy.decide(agentConnected: isConnected,
                                                      presence: presence,
                                                      sinceLastLaunch: since,
                                                      grace: grace,
                                                      autoReattach: autoReattach(),
                                                      stopped: isStopped)

        // Published on every probe whatever the decision: arming state is the one channel for
        // "is this transport working".
        onPresence(presence, isConnected)
        announceIfNew(presence)

        switch decision {
        case .doNothing:
            return
        case .askUser:
            // The banner is already up via `onPresence` → `.detached`; the next move is theirs.
            return
        case .relaunchInstrumented:
            let allowed = withLock {
                guard autoRelaunchesUsed < autoRelaunchBudget else { return false }
                autoRelaunchesUsed += 1
                return true
            }
            guard allowed else {
                onStatus("network agent: \(key.bundleID) came back without the agent again — "
                    + "relaunch it from the banner to try once more.")
                return
            }
            await relaunchNow()
        }
    }

    private func announceIfNew(_ presence: SimulatorProcesses.Presence) {
        let isNew = withLock {
            guard lastAnnounced != presence else { return false }
            lastAnnounced = presence
            return true
        }
        guard isNew else { return }
        switch presence {
        case .notBooted:
            onStatus("network agent: the simulator isn’t booted any more.")
        case .notRunning:
            onStatus("network agent: \(key.bundleID) isn’t running — open it to resume capturing.")
        case .running:
            onStatus("network agent: \(key.bundleID) is running without the Jaca agent.")
        }
    }

    // MARK: - Locking

    private var isConnected: Bool { withLock { connected } }
    private var isStopped: Bool { withLock { stopped } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
