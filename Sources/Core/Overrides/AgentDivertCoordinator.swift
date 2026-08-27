import Foundation

/// Owns everything that has to exist for a diverted request to reach Jaca: the loopback
/// `OverrideServer`, the `adb reverse` tunnel, and the control frames that tell the agent which
/// hosts to route.
///
/// **The port is allocated once and never changes for the life of the owning `AgentController`.**
/// That is a deliberate structural choice: `SqueezeAgent.attach()` early-returns when capture is
/// already loaded, so anything baked into the attach spec is frozen until the app is force-stopped.
/// Changing a port mid-session would leave the app rewriting to a dead port and failing every
/// request on that host. Rules change freely *behind* the stable port instead, which is what makes
/// "edit a rule, it applies on the next request" true with no re-attach.
final class AgentDivertCoordinator: @unchecked Sendable {

    /// What the UI shows about whether overrides are actually running here.
    enum State: Sendable, Equatable {
        case idle
        case active(port: Int, hosts: Set<String>)
        case failed(String)
    }

    private let adbPath: String
    private let serial: String
    private let package: String
    private let heartbeatSeconds: Int
    private let onStatus: @Sendable (String) -> Void
    private let onStateChange: @Sendable (State) -> Void

    private let lock = NSLock()
    private var server: OverrideServer?
    private var reversePort: Int?
    private var desiredHosts: Set<String> = []
    private var agentSupportsOverride = false
    /// Sticky: once this device's agent has advertised `override/1`, later reconnects are the
    /// same build and can be re-armed without waiting for a hello we might miss.
    private var everSupportedOverride = false
    private var state: State = .idle {
        didSet { if state != oldValue { onStateChange(state) } }
    }

    /// Writes control frames to the agent. Supplied by `AgentController`, which owns the socket.
    var sendControlFrame: (@Sendable (String) -> Void)?

    init(adbPath: String, serial: String, package: String, heartbeatSeconds: Int = 15,
         onStatus: @escaping @Sendable (String) -> Void = { _ in },
         onStateChange: @escaping @Sendable (State) -> Void = { _ in }) {
        self.adbPath = adbPath
        self.serial = serial
        self.package = package
        self.heartbeatSeconds = heartbeatSeconds
        self.onStatus = onStatus
        self.onStateChange = onStateChange
    }

    var currentState: State { withLock { state } }

    // MARK: - Lifecycle

    // Locking is confined to these synchronous helpers: taking an `NSLock` directly inside an
    // async function is unsafe across suspension points (and an error under Swift 6).

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Claims the right to start, so a second concurrent `start` is a no-op.
    private func claimStart() -> Bool {
        withLock { server == nil }
    }

    private func finishStart(server newServer: OverrideServer, port: Int) -> Set<String> {
        withLock {
            server = newServer
            reversePort = port
            return desiredHosts
        }
    }

    private func takeDownState() -> (server: OverrideServer?, port: Int?) {
        withLock {
            let s = server
            let p = reversePort
            server = nil
            reversePort = nil
            agentSupportsOverride = false
            return (s, p)
        }
    }

    /// Binds the server and opens the tunnel. Idempotent — a second call is a no-op.
    func start(pipeline: InterceptPipeline) async {
        guard claimStart() else { return }

        let newServer = OverrideServer(pipeline: pipeline,
                                       transport: .agentDivert(package: package),
                                       deviceID: serial, appID: package)
        do {
            try newServer.start()
        } catch {
            setState(.failed("Couldn't start the override server: \(error.localizedDescription)"))
            return
        }
        let port = newServer.boundPort
        guard port > 0 else {
            newServer.stop()
            setState(.failed("The override server didn't bind to a port."))
            return
        }

        // Same port on both sides: `adb reverse tcp:P tcp:P` needs no stdout parsing, and an
        // OS-allocated port can't collide with anything already forwarded.
        let result = await run(["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
        guard result.exitCode == 0 else {
            newServer.stop()
            JacaLog.error("override", "adb reverse tcp:\(port) failed — \(result.text)")
            setState(.failed("adb reverse tcp:\(port) failed — \(result.text)"))
            return
        }
        AdbTunnelCleanup.register(adbPath: adbPath, serial: serial, kind: .reverse, port: port)
        JacaLog.info("override", "server bound 127.0.0.1:\(port), adb reverse tcp:\(port) ok (\(package))")

        let hosts = finishStart(server: newServer, port: port)
        setState(.active(port: port, hosts: hosts))
        pushEndpoint()
    }

    /// Tears everything down in the order that leaves nothing pointing at a dead listener:
    /// disarm the agent first, then remove the tunnel, then close the server.
    func stop() async {
        let (currentServer, port) = takeDownState()

        // (a) Tell the agent to stop diverting, and flush before anything else goes away.
        sendControlFrame?(Self.divertFrame(origin: nil, hosts: [], heartbeatSeconds: heartbeatSeconds))

        // (b) Remove the tunnel, so a stale reverse can't outlive the listener.
        if let port {
            _ = await run(["-s", serial, "reverse", "--remove", "tcp:\(port)"])
            AdbTunnelCleanup.deregister(adbPath: adbPath, serial: serial, kind: .reverse, port: port)
        }
        // (c) Close the listener.
        currentServer?.stop()
        JacaLog.info("override", "divert torn down (\(package))")
        setState(.idle)
    }

    // MARK: - Control channel

    /// Called when the agent's hello frame advertises `override/1`. Until then the desktop sends
    /// nothing, so an older agent build is a no-op rather than a hazard.
    func agentDidAdvertiseOverrideSupport() {
        JacaLog.info("override", "agent advertised override/1 (\(package))")
        withLock {
            agentSupportsOverride = true
            everSupportedOverride = true
        }
        pushEndpoint()
    }

    /// Called whenever the reader reconnects: a re-attach re-points the reporter socket, so the
    /// endpoint has to be re-sent rather than sent once.
    func agentDidReconnect() {
        // Only the *first* connection has to prove the agent understands control frames. After
        // that, assume it: waiting for a hello that got missed would strand the device unarmed
        // with no way back, and the heartbeat re-states the endpoint anyway.
        let stillSupported = withLock {
            agentSupportsOverride = everSupportedOverride
            return everSupportedOverride
        }
        JacaLog.info("override",
            "agent socket reconnected (\(package)); re-arming=\(stillSupported)")
        if stillSupported { pushEndpoint() }
    }

    /// Updates which hosts the device should route. Takes effect on the app's next request.
    func updateHosts(_ hosts: Set<String>) {
        let port: Int? = withLock {
            guard hosts != desiredHosts else { return nil }
            desiredHosts = hosts
            return reversePort ?? -1        // -1 distinguishes "changed but not bound yet"
        }
        guard let port else { return }      // nothing changed
        if port > 0 { setState(.active(port: port, hosts: hosts)) }
        pushEndpoint()
    }

    /// Keeps the agent's dead-man switch fed **and re-states the endpoint**, so the device is
    /// re-armed automatically within one heartbeat of any desync.
    ///
    /// This used to send a bare `{"type":"ping"}`, which could only refresh the timer — it could
    /// never re-arm. That made every desync permanent: the device's `disarm()` clears `origin`
    /// until a new `divert` frame arrives, and frames were only sent on start, on hello, or on a
    /// host change. So if the app restarted (fresh process, `origin == null`) without the desktop
    /// noticing the socket drop, or a single 15 s window lapsed, overrides went dead for good
    /// while the toolbar still claimed they were active — "worked at first, then stopped".
    ///
    /// `Divert.configure` is idempotent and refreshes `lastControlAt`, so re-sending the endpoint
    /// is both the keepalive and the repair. It costs a few hundred bytes every 5 s.
    func sendHeartbeat() {
        let armed = withLock { agentSupportsOverride && server != nil }
        guard armed else { return }
        pushEndpoint()
    }

    private func pushEndpoint() {
        let (port, hosts, supported) = withLock { (reversePort, desiredHosts, agentSupportsOverride) }

        guard supported, let port else {
            JacaLog.debug("override",
                "endpoint not pushed (agentSupportsOverride=\(supported), port=\(String(describing: port)))")
            return
        }
        // No hosts means divert nothing — never "divert everything".
        let origin = hosts.isEmpty ? nil : "http://localhost:\(port)"
        sendControlFrame?(Self.divertFrame(origin: origin, hosts: hosts,
                                           heartbeatSeconds: heartbeatSeconds))
        JacaLog.debug("override", "endpoint -> origin=\(origin ?? "nil") hosts=\(hosts.sorted())")
    }

    /// The **entire** desktop→device vocabulary: an origin, a host set, and a heartbeat window.
    static func divertFrame(origin: String?, hosts: Set<String>, heartbeatSeconds: Int) -> String {
        let hostList = hosts.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        let originJSON = origin.map { "\"\($0)\"" } ?? "null"
        return "{\"type\":\"divert\",\"origin\":\(originJSON),\"hosts\":[\(hostList)]," +
               "\"heartbeatSeconds\":\(heartbeatSeconds)}"
    }

    private func setState(_ newValue: State) {
        withLock { state = newValue }
    }

    private func run(_ args: [String]) async -> (exitCode: Int32, text: String) {
        guard let result = try? await CommandRunner.run(URL(fileURLWithPath: adbPath), args) else {
            return (-1, "couldn't run adb")
        }
        let text = ((result.stderr) + " " + (result.stdout))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.exitCode, text.isEmpty ? "exit \(result.exitCode)" : text)
    }
}
