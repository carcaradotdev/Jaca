import Foundation

/// Owns everything a diverted request needs to reach Jaca: the loopback `OverrideServer`, the
/// tunnel (if the transport needs one), and the control frames naming the hosts to route.
///
/// The port is allocated once and never changes: `SqueezeAgent.attach()` early-returns when
/// capture is already loaded, so anything in the attach spec is frozen until a force-stop. Rules
/// change behind the stable port instead, which is what makes "applies on the next request" true.
final class DivertCoordinator: @unchecked Sendable {

    private let transport: InterceptTransportID
    private let deviceID: String
    private let appID: String
    /// What the wired capture source declared it can honour, so the pipeline's clamp is the
    /// same value the toolbar shows.
    private let capabilities: InterceptCapabilities
    /// How the device reaches our loopback port: `SharedLoopbackTunnel` (Simulator, nothing to
    /// open) or `AdbReverseTunnel` (Android).
    private let tunnel: any DivertTunnel
    /// Where control frames go. Injected, so this class never owns an fd.
    private let writer: any AgentControlWriter
    private let heartbeatSeconds: Int
    private let onStateChange: @Sendable (DivertCoordinator, InterceptArmingState) -> Void

    private let lock = NSLock()
    private var server: OverrideServer?
    /// The port `OverrideServer` bound. The tunnel maps it 1:1, so it's the device-side port too.
    private var serverPort: Int?
    private var desiredHosts: Set<String> = []
    private var agentSupportsOverride = false
    /// Sticky: once this agent has advertised `override/1`, reconnects are the same build and
    /// re-arm without waiting for a hello we might miss.
    private var everSupportedOverride = false
    /// Hello arrived without `override/1` — a rebuild, not a wait.
    private var agentIsTooOld = false
    /// The supervisor's last report about the target process; nil when nothing looked (Android
    /// never does). Only set while the agent's socket is down, cleared by the next hello.
    private var appPresence: SimulatorProcesses.Presence?
    private var state: InterceptArmingState = .idle {
        didSet { if state != oldValue { onStateChange(self, state) } }
    }
    private var heartbeatTask: Task<Void, Never>?
    /// Terminal once `stop()` has run; a coordinator is one-shot. Refusing a late `start()`
    /// closes a leak: teardown can land while the controller is mid-bring-up, and the resumed
    /// `start()` would bind a second `OverrideServer` plus a heartbeat nothing is left to cancel.
    private var stopped = false

    init(transport: InterceptTransportID,
         deviceID: String,
         appID: String,
         capabilities: InterceptCapabilities,
         tunnel: any DivertTunnel,
         writer: any AgentControlWriter,
         heartbeatSeconds: Int = 15,
         onStateChange: @escaping @Sendable (DivertCoordinator, InterceptArmingState) -> Void = { _, _ in }) {
        self.transport = transport
        self.deviceID = deviceID
        self.appID = appID
        self.capabilities = capabilities
        self.tunnel = tunnel
        self.writer = writer
        self.heartbeatSeconds = heartbeatSeconds
        self.onStateChange = onStateChange
    }

    /// Derived from the window it has to stay inside, so an edit can't leave it outliving that.
    static func heartbeatInterval(heartbeatSeconds: Int) -> Duration {
        .seconds(max(1, heartbeatSeconds / 3))
    }

    var currentState: InterceptArmingState { withLock { state } }

    /// Whether `stop()` has run. A torn-down coordinator may be replaced in the registry (the
    /// ordinary restart); a live one still belongs to a tab.
    var isStopped: Bool { withLock { stopped } }

    // MARK: - Lifecycle

    // Locking stays in these synchronous helpers: holding an `NSLock` across a suspension point
    // is unsafe (and an error under Swift 6).

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Claims the right to start, so a second concurrent `start` is a no-op.
    private func claimStart() -> Bool {
        withLock { server == nil && !stopped }
    }

    /// Commits the bring-up — unless `stop()` landed while `tunnel.open` was in flight.
    /// `claimStart()` only tests `stopped` on entry, and a `stop()` inside that window sees no
    /// server to take down, so without this check the resumed `start` publishes an unstoppable
    /// listener + heartbeat while the toolbar sits on "Arming" forever.
    private func finishStart(server newServer: OverrideServer, port: Int) -> Bool {
        withLock {
            guard !stopped else { return false }
            server = newServer
            serverPort = port
            refreshStateLocked()
            return true
        }
    }

    private func takeDownState() -> (server: OverrideServer?, port: Int?) {
        withLock {
            let s = server
            let p = serverPort
            server = nil
            serverPort = nil
            agentSupportsOverride = false
            agentIsTooOld = false
            appPresence = nil
            return (s, p)
        }
    }

    /// Binds the server and opens the tunnel. Idempotent — a second call is a no-op.
    ///
    /// Publishes `.waitingForAgent` on success, never `.active`: nothing is diverted until the
    /// agent has said hello, and the toolbar renders `.active` as a live green bolt.
    func start(pipeline: InterceptPipeline) async {
        guard claimStart() else { return }

        let newServer = OverrideServer(pipeline: pipeline, transport: transport,
                                       deviceID: deviceID, appID: appID,
                                       capabilities: capabilities)
        do {
            try newServer.start()
        } catch {
            // A stop() after `claimStart()` already published `.idle`; `refreshStateLocked`
            // needs a `server`, so it could never clear a `.failed` written over it.
            if !isStopped {
                setState(.failed("Couldn't start the override server: \(error.localizedDescription)"))
            }
            return
        }
        let port = newServer.boundPort
        guard port > 0 else {
            newServer.stop()
            if !isStopped { setState(.failed("The override server didn't bind to a port.")) }
            return
        }

        do {
            try await tunnel.open(localPort: port)
        } catch {
            newServer.stop()
            // As above: don't overwrite the `.idle` a concurrent stop() published.
            guard !isStopped else { return }
            // The transport that knows what failed is the one that words it.
            let message = (error as? DivertTunnelError)?.userMessage ?? error.localizedDescription
            setState(.failed(message))
            return
        }
        JacaLog.info("override", "server bound 127.0.0.1:\(port) (\(appID))")

        guard finishStart(server: newServer, port: port) else {
            // stop() ran during `tunnel.open` and found nothing to release — undo it in the
            // order stop() would have: tunnel first, then listener.
            await tunnel.close(localPort: port)
            newServer.stop()
            JacaLog.info("override", "bring-up abandoned — stop landed mid-start (\(appID))")
            return
        }
        pushCurrentEndpoint()
        startHeartbeat()
    }

    /// Marks this coordinator as tearing down — **synchronously**, and idempotently.
    ///
    /// `stop()` is async and runs inside a teardown `Task`, so the coordinator would otherwise
    /// still read as live while `restartForInterceptChange()` registers its replacement in the
    /// same main-actor run: the registry refuses the newcomer, then the outgoing teardown removes
    /// the entry, leaving the target permanently unregistered.
    func beginStop() {
        withLock { stopped = true; heartbeatTask?.cancel(); heartbeatTask = nil }
    }

    func stop() async {
        beginStop()
        let (currentServer, port) = takeDownState()

        // (a) Tell the agent to stop diverting, and flush before anything else goes away —
        // without the flush the ordering only held by accident, via the `adb` spawn below.
        push(.disarmed(heartbeatSeconds: heartbeatSeconds))
        await writer.flush()

        // (b) Remove the tunnel, so a stale mapping can't outlive the listener.
        if let port { await tunnel.close(localPort: port) }
        // (c) Close the listener.
        currentServer?.stop()
        JacaLog.info("override", "divert torn down (\(appID))")
        setState(.idle)
    }

    // MARK: - Control channel

    /// Called when the agent's hello frame advertises `override/1`. Until then the desktop sends
    /// nothing, so an older agent build is a no-op rather than a hazard.
    func agentDidAdvertiseOverrideSupport() {
        JacaLog.info("override", "agent advertised override/1 (\(appID))")
        withLock {
            agentSupportsOverride = true
            everSupportedOverride = true
            agentIsTooOld = false
            // A hello comes from a live socket inside the app, so the supervisor's last report
            // is stale by definition.
            appPresence = nil
            refreshStateLocked()
        }
        pushCurrentEndpoint()
    }

    /// Called when the agent said hello without `override/1`. The socket is fine, so silence
    /// would look like "still loading" forever — this needs a rebuild, and the user must be told.
    func agentDidAdvertiseWithoutOverrideSupport() {
        JacaLog.warn("override", "agent hello lacks override/1 (\(appID)) — agent build predates overrides")
        withLock {
            agentSupportsOverride = false
            agentIsTooOld = true
            appPresence = nil
            refreshStateLocked()
        }
    }

    /// Called whenever the reader reconnects: a re-attach re-points the reporter socket, so the
    /// endpoint has to be re-sent rather than sent once.
    func agentDidReconnect() {
        // Only the *first* connection has to prove the agent understands control frames: waiting
        // for a hello we might have missed would strand the device unarmed with no way back.
        let stillSupported = withLock {
            agentSupportsOverride = everSupportedOverride
            refreshStateLocked()
            return everSupportedOverride
        }
        JacaLog.info("override",
            "agent socket reconnected (\(appID)); re-arming=\(stillSupported)")
        if stillSupported { pushCurrentEndpoint() }
    }

    /// The supervisor's report about the target process, gathered only while the agent's socket
    /// is down. Purely a state change — this class never (re)launches anything.
    ///
    /// Needed because `agentDidReconnect` keeps `override/1` support sticky across a socket
    /// cycle: without an outside report, a quit app would keep publishing `.active` forever.
    func appPresenceChanged(_ presence: SimulatorProcesses.Presence) {
        withLock {
            appPresence = presence
            refreshStateLocked()
        }
    }

    /// Updates which hosts the device should route. Takes effect on the app's next request.
    func updateHosts(_ hosts: Set<String>) {
        let changed = withLock {
            guard hosts != desiredHosts else { return false }
            desiredHosts = hosts
            refreshStateLocked()
            return true
        }
        guard changed else { return }
        pushCurrentEndpoint()
    }

    /// Feeds the agent's dead-man switch. If Jaca dies these stop and the agent disarms itself,
    /// which is why a SIGKILL can't leave the app pointed at a dead tunnel.
    private func startHeartbeat() {
        let interval = Self.heartbeatInterval(heartbeatSeconds: heartbeatSeconds)
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.sendHeartbeat()
            }
        }
        // Same race one step later: a stop() between `finishStart` and here already ran its
        // `heartbeatTask?.cancel()`, so installing unconditionally would strand this task.
        let installed = withLock {
            guard !stopped else { return false }
            heartbeatTask?.cancel()
            heartbeatTask = task
            return true
        }
        if !installed { task.cancel() }
    }

    /// Re-states the endpoint rather than pinging, so any desync repairs itself within one
    /// heartbeat. A bare ping can only refresh the timer: the device's `disarm()` clears `origin`
    /// until a new `divert` frame arrives, so a missed socket drop or a lapsed window would kill
    /// overrides for good. `Divert.configure` is idempotent, so this is keepalive and repair.
    private func sendHeartbeat() {
        let armed = withLock { agentSupportsOverride && server != nil }
        guard armed else { return }
        pushCurrentEndpoint()
    }

    /// Sends the endpoint the current state implies, or stays silent until the agent has proven
    /// it understands control frames.
    private func pushCurrentEndpoint() {
        let (port, hosts, supported) = withLock { (serverPort, desiredHosts, agentSupportsOverride) }

        guard supported, let port else {
            JacaLog.debug("override",
                "endpoint not pushed (agentSupportsOverride=\(supported), port=\(String(describing: port)))")
            return
        }
        // `OverrideEndpoint`'s init clears origin and hosts together, so an empty host set here
        // disarms the device rather than diverting everything.
        push(OverrideEndpoint(origin: tunnel.origin(forLocalPort: port), hosts: hosts,
                              heartbeatSeconds: heartbeatSeconds))
    }

    /// The single funnel: `OverrideEndpoint.divertFrame` is called from nowhere else, because a
    /// second encoder is how the two device-side twins drift out of sync with the desktop.
    private func push(_ endpoint: OverrideEndpoint) {
        writer.write(OverrideEndpoint.divertFrame(endpoint))
        JacaLog.debug("override",
            "endpoint -> origin=\(endpoint.origin ?? "nil") hosts=\(endpoint.hosts.sorted())")
    }

    private func setState(_ newValue: InterceptArmingState) {
        withLock { state = newValue }
    }

    /// Derives the published state from what is true right now, so every caller reports the same
    /// answer. Call sites hold `lock`. Never fires before the server exists: a failed start keeps
    /// its `.failed` message and an unstarted coordinator stays `.idle`.
    private func refreshStateLocked() {
        guard server != nil, let port = serverPort else { return }
        // A process report outranks the sticky hello (see `appPresenceChanged`); the supervisor
        // only reports while the socket is down, so it can't shout over a healthy session.
        if let appPresence {
            state = .forPresence(appPresence, appID: appID)
            return
        }
        if agentSupportsOverride {
            state = .active(port: port, hosts: desiredHosts)
        } else if agentIsTooOld {
            state = .agentTooOld
        } else {
            state = .waitingForAgent
        }
    }
}
