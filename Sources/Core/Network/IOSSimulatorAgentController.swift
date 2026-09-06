import Foundation

/// Composes the in-process capture session for one app on the iOS **Simulator** — no proxy, no
/// CA. Owns no socket framing and no launch argv (those live in `AgentLineChannel` and
/// `SimulatorAgentLaunch`/`SimulatorAppLauncher`): it only wires collaborators and forwards
/// their events.
///
/// The simulator shares the Mac's loopback, so there is nothing to tunnel and **no second socket
/// in either direction**: the injected agent dials `127.0.0.1:<port>` and Jaca writes its divert
/// frames back down the very connection it already reads transactions from.
final class IOSSimulatorAgentController: @unchecked Sendable {
    private let udid: String
    private let bundleID: String
    private let agentDylib: URL
    private let onTransaction: @Sendable (NetworkTransaction) -> Void
    private let onStatus: @Sendable (String) -> Void
    /// Reports "the agent is no longer in the app" independently of the coordinator, because
    /// losing the agent stops **capture**, not just overrides — and `divert` is nil whenever
    /// response overrides are off, which is the default.
    private let onAttach: @Sendable (InterceptArmingState) -> Void

    /// Owns the override server and the control frames; nil when overrides aren't wired. A `let`
    /// built in `init`: `NetworkSession.interceptWired` is only re-evaluated when `current` is
    /// assigned, so a later coordinator would leave the toolbar reading as unarmed forever.
    let divert: DivertCoordinator?
    private let interceptPipeline: InterceptPipeline?
    private let intercept: InterceptServices?
    private let target: InterceptTarget

    /// The socket to the agent, including its lock, `SO_NOSIGPIPE` and the line framing.
    private let channel: AgentLineChannel
    /// Notices when the app comes back **without** the agent. Event-driven, so it costs nothing
    /// while the agent is connected.
    private let supervisor: SimulatorAttachSupervisor
    /// The channel has to exist before `self` does — the coordinator takes it as its writer — so
    /// its callbacks reach back through this box, filled in at the end of `init`.
    private let weakSelf = WeakSimulatorController()

    /// Distinguishes this session's launch claim from another tab's, so `release` can never drop
    /// a claim a newer session already took.
    private let owner = "network-\(UUID().uuidString)"
    private var launchKey: SimulatorAppLauncher.Key { .init(udid: udid, bundleID: bundleID) }
    /// Set once the agent's first bytes arrive — i.e. it actually loaded in-process. Drives the
    /// "launched but never loaded" diagnostic.
    private let agentLoaded = SimulatorAgentFlag()
    private var stopped = false

    init(udid: String, bundleID: String, agentDylib: URL,
         capabilities: InterceptCapabilities,
         onTransaction: @escaping @Sendable (NetworkTransaction) -> Void,
         onStatus: @escaping @Sendable (String) -> Void,
         onAttach: @escaping @Sendable (InterceptArmingState) -> Void = { _ in },
         intercept: InterceptServices? = nil) {
        self.udid = udid
        self.bundleID = bundleID
        self.agentDylib = agentDylib
        self.onTransaction = onTransaction
        self.onStatus = onStatus
        self.onAttach = onAttach
        self.interceptPipeline = intercept?.pipeline(for: .iosSimulatorDivert(bundleID: bundleID),
                                                     deviceID: udid, appID: bundleID)
        let box = self.weakSelf
        let channel = AgentLineChannel(name: "ios-\(bundleID)", callbacks: .init(
            onLine: { box.controller?.handle(line: $0) },
            onFirstBytes: { box.controller?.noteAgentLoaded() },
            // On *disconnect*, matching the Android controller: the re-arm rides the next hello
            // or heartbeat, so a relaunched agent is never spoken to first. The supervisor wakes
            // here too — a dropped socket is the only event that separates "the user quit the
            // app" from "capture is quietly working".
            onDisconnected: {
                box.controller?.divert?.agentDidReconnect()
                box.controller?.supervisor.agentDisconnected()
            }))
        self.channel = channel
        self.supervisor = SimulatorAttachSupervisor(
            key: .init(udid: udid, bundleID: bundleID),
            relaunch: {
                guard let controller = box.controller else { return }
                await controller.relaunchToAttach()
            },
            // One vocabulary for "is this transport working": presence maps to the same
            // `InterceptArmingState` every override surface renders, and is published
            // unconditionally — the coordinator *also* gets it when overrides are wired.
            onPresence: { presence, _ in
                guard let controller = box.controller else { return }
                controller.onAttach(.forPresence(presence, appID: bundleID))
                controller.divert?.appPresenceChanged(presence)
            },
            onStatus: { onStatus($0) })
        let target = InterceptTarget(deviceID: udid, package: bundleID)
        self.divert = intercept.map { services in
            DivertCoordinator(transport: .iosSimulatorDivert(bundleID: bundleID),
                              deviceID: udid, appID: bundleID,
                              capabilities: capabilities,
                              tunnel: SharedLoopbackTunnel(),
                              writer: channel,
                              onStateChange: { services.reportArming(target: target, coordinator: $0, state: $1) })
        }
        self.intercept = intercept
        self.target = target
        if let divert = self.divert { intercept?.register(target: target, coordinator: divert) }
        box.controller = self
    }

    // MARK: - Lifecycle

    /// **Load-bearing ordering: arm before launching.** The server and endpoint must exist before
    /// the app's process does, or the first request — usually the one the user wanted to override
    /// — goes straight past us. `AgentController.run()` arms before `attach-agent` for the same
    /// reason.
    func start() {
        stopped = false
        guard let port = channel.listen() else {
            fail("couldn't open the local listener the agent connects back to")
            return
        }
        Task { await bringUp(port: port) }
    }

    private func bringUp(port: UInt16) async {
        do {
            try await SimulatorAppLauncher.shared.claim(
                launchKey, owner: owner,
                childEnvironment: SimulatorAgentLaunch.childEnvironment(agentDylib: agentDylib,
                                                                        port: port))
        } catch {
            // Two agents in one app leaves the older tab dialling a dead port, stuck at
            // "arming…" forever. Fail loudly instead.
            fail("another Network tab is already capturing \(bundleID) on this simulator")
            return
        }
        // `stop()` hands the claim back synchronously, so a stop landing while this awaited
        // `claim` released nothing and the claim just taken is an orphan — `\(bundleID)` can't be
        // captured again until Jaca restarts. Every early return below has to give it back.
        guard !stopped else { return releaseClaim() }

        if let divert, let interceptPipeline { await divert.start(pipeline: interceptPipeline) }
        guard !stopped else { return releaseClaim() }

        onStatus("network agent: launching \(bundleID)…")
        guard await SimulatorAppLauncher.shared.launch(launchKey, terminateRunning: true) else {
            // Nothing is running, so the exclusive claim only costs other tabs the app.
            // `release` is owner-checked, so a later `stop()` is a no-op.
            releaseClaim()
            fail("couldn't launch \(bundleID)")
            return
        }
        onStatus("network agent: in-process (\(bundleID))")
        supervisor.noteLaunched()
        scheduleAgentLoadCheck()
    }

    /// Gives the launcher claim back. Safe to call when nothing is claimed.
    private func releaseClaim() {
        SimulatorAppLauncher.shared.release(launchKey, owner: owner)
    }

    /// The consented re-attach (the banner's action), relaunching through the same claim so the
    /// injection environment travels with it. The only path that restarts the user's app.
    func relaunchToAttach() async {
        guard !stopped else { return }
        onStatus("network agent: relaunching \(bundleID) with the agent…")
        guard await SimulatorAppLauncher.shared.launch(launchKey, terminateRunning: true) else {
            fail("couldn't relaunch \(bundleID)")
            return
        }
        supervisor.noteLaunched()
        scheduleAgentLoadCheck()
    }

    /// Order matters: stop accepting but leave the live fd open, so the disarm frame still
    /// reaches the agent. Clearing the connection first makes every teardown write bail, leaving
    /// the device to recover only via the dead-man window.
    func stop() {
        stopped = true
        supervisor.stop()
        let coordinator = divert
        let services = intercept, target = target

        // Synchronously, before the teardown Task: `restartForInterceptChange()` stops and starts
        // in one straight line, so a deferred release loses to the next controller's `claim` and
        // the restart dies with "another Network tab is already capturing…".
        // Both synchronous: a restart builds the replacement in the same main-actor run, so
        // anything deferred into the teardown Task loses that race.
        coordinator?.beginStop()
        releaseClaim()

        channel.stopAccepting()
        Task {
            await coordinator?.stop()          // disarm, then close the override server
            await self.channel.flush()         // the disarm frame has reached send(2)
            self.channel.close()
            // Drop the coordinator so a closed tab stops receiving host-set updates.
            if let coordinator { services?.deregister(target: target, coordinator: coordinator) }
        }
    }

    // MARK: - Events

    /// One agent line, routed. Both controllers classify through `AgentFrame`, so their readers
    /// can't drift apart.
    private func handle(line: String) {
        switch AgentFrame.classify(line) {
        case .transaction(let txn):
            onTransaction(txn)
        case .hello(let supportsOverride):
            // A pre-overrides agent never reads its socket, so reporting it turns an eternal
            // "arming…" into a sentence that names the fix.
            guard supportsOverride else { divert?.agentDidAdvertiseWithoutOverrideSupport(); return }
            JacaLog.info("agent", "hello with override/1 from \(bundleID)")
            divert?.agentDidAdvertiseOverrideSupport()
        case .unrecognised:
            break
        }
    }

    private func noteAgentLoaded() {
        agentLoaded.set()
        // First bytes, not `accept`: proof the dylib loaded *inside* the app, which is what lets
        // the supervisor cancel its timers.
        supervisor.agentConnected()
        // The agent is back, so clear any detach we reported — otherwise a recovered session
        // keeps the banner up for life.
        onAttach(.idle)
        onStatus("network agent: connected (\(bundleID))")
    }

    /// Nothing connected after a successful launch means the dylib didn't load — say so, and
    /// where to look, rather than sitting on "in-process".
    private func scheduleAgentLoadCheck() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !self.stopped, !self.agentLoaded.isSet else { return }
            self.onStatus("network agent: \(self.bundleID) launched but the agent never connected — "
                + "\(self.agentDylib.lastPathComponent) likely failed to load. It has to be built for "
                + "the arm64 simulator; check the app's stderr in the Logs tab.")
        }
    }

    /// A failure *before* the coordinator started never reaches it, so it goes straight to the
    /// same sink — otherwise the toolbar sits on `.idle`, which reads as "nothing is wired here".
    private func fail(_ message: String) {
        onStatus("network agent: \(message)")
        intercept?.reportArming(target: target, coordinator: divert, state: .failed(message))
    }
}

/// Lets `AgentLineChannel`'s callbacks reach the controller, which doesn't exist yet when the
/// channel is built.
private final class WeakSimulatorController: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: IOSSimulatorAgentController?
    var controller: IOSSimulatorAgentController? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// A one-way flag set from the reader thread and read from a `Task`.
private final class SimulatorAgentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
