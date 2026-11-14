import Foundation

/// Captures an iOS Simulator through the Mac system proxy. Simulator apps use the network of
/// the Mac, so the capture points the Mac system proxy at a MITM proxy on loopback. The proxy
/// decrypts only connections that come from a process of a simulator with a running capture.
/// It relays every other connection of the Mac raw and records nothing of it.
///
/// All simulator captures in the process share one proxy and one system-proxy lease, through
/// `SimulatorProxyHub`. The capture never installs the CA: the simulator must trust it first.
@MainActor
final class SimulatorProxyCaptureSource: CaptureSource {
    let device: Device
    private let ca: CertificateAuthority?
    private let intercept: InterceptServices?
    private let hub: SimulatorProxyHub
    private weak var sink: CaptureSink?
    /// True from `start` until `stop`, or until the hub fails this capture.
    private(set) var joined = false

    convenience init(device: Device, ca: CertificateAuthority?, intercept: InterceptServices?) {
        self.init(device: device, ca: ca, intercept: intercept, hub: .shared)
    }

    init(device: Device, ca: CertificateAuthority?, intercept: InterceptServices?, hub: SimulatorProxyHub) {
        self.device = device
        self.ca = ca
        self.intercept = intercept
        self.hub = hub
    }

    /// The capture changes a setting of the whole Mac.
    static let claim: DeviceClaim = .macSystemProxy

    var interceptCapabilities: InterceptCapabilities { intercept == nil ? [] : .desktopTerminated }
    /// Nothing to arm: the proxy is the only path, so the rules run whenever it listens.
    var interceptWired: Bool { intercept != nil }

    func start(into sink: CaptureSink) {
        self.sink = sink
        guard !joined else { return }
        guard let ca else {
            sink.capture(didChangeStatus: "Couldn’t read Jaca’s certificate. Check ~/.jaca/jacad.log.")
            return
        }
        joined = true
        hub.join(self, ca: ca, intercept: intercept)
    }

    func stop() {
        guard joined else { return }
        joined = false
        hub.leave(self)
    }

    func caTrustChanged() {
        hub.caTrustChanged(deviceID: device.id)
    }

    // MARK: - Events from the hub

    func hubDidStart(port: Int) {
        sink?.capture(didBindPort: port)
        sink?.capture(didChangeStatus: "Capturing this device through Jaca's proxy")
    }

    /// The hub could not start the proxy or set the system proxy, and dropped this capture.
    func hubDidFail(_ message: String) {
        joined = false
        sink?.capture(didChangeStatus: message)
    }

    func hubDidReceive(_ transaction: NetworkTransaction) {
        sink?.capture(didReceive: transaction)
    }

    func hubDidPassThrough(host: String) {
        sink?.capture(didChangeStatus: "Passing \(host) through — it rejects the certificate")
    }

    func hubNeedsSetup() {
        sink?.captureNeedsSetup()
    }

    // MARK: - Readiness (used as the descriptor's precheck)

    /// The simulator must be booted. adb is not needed.
    static func precheck(device: Device) async -> String? {
        await precheck(device: device, listBooted: {
            let result = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "list", "devices", "booted"])
            return result?.stdout
        })
    }

    /// `listBooted` returns the output of `simctl list devices booted`, or nil when simctl fails.
    static func precheck(device: Device, listBooted: @Sendable () async -> String?) async -> String? {
        let output = await listBooted() ?? ""
        guard SimulatorProxyRouting.isListed(udid: device.id, in: output) else {
            // The same text as `AgentCaptureSource.unavailableMessage` for a simulator.
            return "\(device.displayModel) isn’t booted — start the simulator and try again."
        }
        return nil
    }
}

// MARK: - Routing (pure)

/// The pure decisions of the shared simulator proxy.
enum SimulatorProxyRouting {
    /// The device id of the capture that owns a client, or nil to relay the client raw.
    /// `udid` is the simulator the client process belongs to; `running` holds the device ids of
    /// the running simulator captures. UDIDs match without regard to case.
    static func deviceID(remoteHost: String, udid: String?, running: Set<String>) -> String? {
        guard isLoopback(remoteHost), let udid else { return nil }
        return running.first { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }

    static func policy(remoteHost: String, udid: String?, running: Set<String>) -> ProxyClientPolicy {
        guard let deviceID = deviceID(remoteHost: remoteHost, udid: udid, running: running) else { return .relayRaw }
        return .intercept(target: ProxyInterceptTarget(deviceID: deviceID))
    }

    /// The proxy binds loopback, so a simulator client always connects from it.
    static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "::1" || host == "::ffff:127.0.0.1"
    }

    /// Whether `simctl list devices booted` lists the simulator.
    static func isListed(udid: String, in output: String) -> Bool {
        !udid.isEmpty && output.range(of: udid, options: .caseInsensitive) != nil
    }
}

// MARK: - Shared proxy

/// The routes of the running simulator captures, read on the proxy's event loops.
final class SimulatorProxyRoutes: @unchecked Sendable {
    struct Route: Sendable {
        /// The capture's rules and reporter. Nil when the capture has no override services.
        var pipeline: InterceptPipeline?
        /// Hosts of this simulator that reject Jaca's certificate.
        var passthrough: TLSPassthroughPolicy
    }

    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    /// The device of each request between its resolve and its report.
    private var pending: [UUID: String] = [:]

    var deviceIDs: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(routes.keys)
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return routes.isEmpty
    }

    func route(_ deviceID: String?) -> Route? {
        guard let deviceID else { return nil }
        lock.lock(); defer { lock.unlock() }
        return routes[deviceID]
    }

    /// Adds a route, or keeps the one that exists, so a second capture of the same simulator
    /// does not reset its passthrough hosts.
    func add(_ deviceID: String, pipeline: InterceptPipeline?) {
        lock.lock(); defer { lock.unlock() }
        if routes[deviceID] == nil {
            routes[deviceID] = Route(pipeline: pipeline, passthrough: TLSPassthroughPolicy())
        }
    }

    func remove(_ deviceID: String) {
        lock.lock(); defer { lock.unlock() }
        routes[deviceID] = nil
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        routes.removeAll()
    }

    /// Notes the device of a request, so its report reaches the same capture.
    func remember(requestID: UUID, deviceID: String?) {
        guard let deviceID else { return }
        lock.lock(); defer { lock.unlock() }
        pending[requestID] = deviceID
    }

    /// The route of a request noted with `remember`. Forgets the request.
    func takeRoute(requestID: UUID) -> Route? {
        lock.lock(); defer { lock.unlock() }
        guard let deviceID = pending.removeValue(forKey: requestID) else { return nil }
        return routes[deviceID]
    }
}

/// Runs the rules of the capture that a request belongs to. No rule applies to a request of a
/// capture without override services.
struct SimulatorRoutingResolver: InterceptResolving {
    let routes: SimulatorProxyRoutes

    func resolve(_ request: InterceptedRequest,
                 capabilities: InterceptCapabilities) -> (InterceptDecision, InterceptSkipReason?) {
        routes.remember(requestID: request.id, deviceID: request.deviceID)
        return routes.route(request.deviceID)?.pipeline?.resolver?.resolve(request, capabilities: capabilities)
            ?? (.proceed, .noRuleMatched)
    }
}

/// Reports to the capture that a request belongs to.
struct SimulatorRoutingReporter: InterceptReporting {
    let routes: SimulatorProxyRoutes

    func report(requestID: UUID, appliedRuleID: UUID?, skipped: InterceptSkipReason?) {
        routes.takeRoute(requestID: requestID)?.pipeline?.reporter?
            .report(requestID: requestID, appliedRuleID: appliedRuleID, skipped: skipped)
    }
}

/// The one proxy for all simulator captures of the process. The first capture starts the
/// proxy on 127.0.0.1 and points the Mac system proxy at it. The last capture to stop restores
/// the system proxy, then stops the proxy. Joins and leaves run in order, one at a time.
@MainActor
final class SimulatorProxyHub {
    static let shared = SimulatorProxyHub()

    /// The simulator UDID of the process that owns a client connection, or nil. Runs on the
    /// proxy's event loop.
    typealias Attribute = @Sendable (ProxyClientInfo) -> String?

    private struct Member {
        let source: SimulatorProxyCaptureSource
        let ca: CertificateAuthority
        var live = false
        var setupRequested = false
    }

    private let systemProxy: MacSystemProxy
    private let attribute: Attribute
    private let origin: OriginRequesting
    private let routes = SimulatorProxyRoutes()
    private var members: [ObjectIdentifier: Member] = [:]
    private var server: ProxyServer?
    private var transition: Task<Void, Never>?

    /// The port of the running proxy, while the system proxy points at it.
    private(set) var port: Int?

    init(systemProxy: MacSystemProxy = .shared,
         attribute: @escaping Attribute = SimulatorProxyHub.liveAttribute(),
         origin: OriginRequesting = OriginClient(upstream: UpstreamClient(),
                                                 policy: InterceptServices.redirectPolicy(for: .mitmProxy))) {
        self.systemProxy = systemProxy
        self.attribute = attribute
        self.origin = origin
    }

    /// Attributes a client with `ConnectionAttributor`, through libproc.
    nonisolated static func liveAttribute() -> Attribute {
        let attributor = ConnectionAttributor()
        return { info in
            guard let client = UInt16(exactly: info.remotePort), let listener = UInt16(exactly: info.localPort),
                  client > 0, listener > 0 else { return nil }
            return attributor.attribute(clientPort: client, listenerPort: listener)?.udid
        }
    }

    var memberCount: Int { members.count }
    var isRunning: Bool { server != nil }

    func join(_ source: SimulatorProxyCaptureSource, ca: CertificateAuthority, intercept: InterceptServices?) {
        let deviceID = source.device.id
        routes.add(deviceID, pipeline: intercept?.pipeline(for: .mitmProxy, deviceID: deviceID, appID: nil))
        members[ObjectIdentifier(source)] = Member(source: source, ca: ca)
        schedule()
    }

    func leave(_ source: SimulatorProxyCaptureSource) {
        guard let member = members.removeValue(forKey: ObjectIdentifier(source)) else { return }
        dropRouteIfUnused(member.source.device.id)
        schedule()
    }

    /// Waits until every join and leave so far has taken effect.
    func settle() async {
        while let current = transition {
            await current.value
            if transition == current { return }
        }
    }

    /// The CA was installed on `deviceID`: decrypt its passed-through hosts again, and let its
    /// captures ask for setup again if a handshake still fails.
    func caTrustChanged(deviceID: String) {
        routes.route(deviceID)?.passthrough.reset()
        for key in Array(members.keys) where members[key]?.source.device.id == deviceID {
            members[key]?.setupRequested = false
        }
    }

    // MARK: - Transitions

    private func schedule() {
        let previous = transition
        transition = Task { [weak self] in
            await previous?.value
            await self?.converge()
        }
    }

    private func converge() async {
        while true {
            if !members.isEmpty, server == nil {
                await open()
            } else if members.isEmpty, server != nil {
                await close()
            } else {
                announce()
                return
            }
        }
    }

    private func open() async {
        guard let ca = members.values.first?.ca else { return }
        let routes = self.routes
        let attribute = self.attribute
        let pipeline = InterceptPipeline(resolver: SimulatorRoutingResolver(routes: routes), origin: origin,
                                         reporter: SimulatorRoutingReporter(routes: routes))
        let hooks = ProxyTargetHooks(
            shouldDecrypt: { target, host in
                routes.route(target.deviceID)?.passthrough.shouldDecrypt(host) ?? true
            },
            onTransaction: { [weak self] target, transaction in
                guard let deviceID = target.deviceID else { return }
                Task { @MainActor in self?.deliver(transaction, to: deviceID) }
            },
            onHandshake: { [weak self] target, host, ok in
                guard let deviceID = target.deviceID, let policy = routes.route(deviceID)?.passthrough else { return }
                let verdict = policy.record(host: host, ok: ok)
                let needsSetup = !ok && !policy.anySuccess
                Task { @MainActor in self?.handshake(deviceID: deviceID, verdict: verdict, needsSetup: needsSetup) }
            })
        let server = ProxyServer(port: 0, ca: ca, pipeline: pipeline, bindHost: "127.0.0.1",
                                 clientPolicy: { info in
                                     // Attribute only while a capture runs: a lookup scans every pid.
                                     guard SimulatorProxyRouting.isLoopback(info.remoteHost), !routes.isEmpty else {
                                         return .relayRaw
                                     }
                                     return SimulatorProxyRouting.policy(remoteHost: info.remoteHost,
                                                                         udid: attribute(info),
                                                                         running: routes.deviceIDs)
                                 },
                                 onTransaction: { _ in },
                                 targetHooks: hooks)
        do {
            try server.start()
        } catch {
            failAll("Couldn’t start the proxy: \(error.localizedDescription)")
            return
        }
        let port = server.boundPort
        switch await systemProxy.acquire(port: port) {
        case .success:
            self.server = server
            self.port = port
        case .failure(let error):
            server.stop()
            DaemonLog.error("simulator capture: couldn't set the Mac system proxy: \(error.message)")
            failAll("Couldn’t set the Mac’s system proxy: \(error.message)")   // COPY-PENDING
        }
    }

    /// Restores the system proxy first, so the Mac never points at a closed port.
    private func close() async {
        guard let server else { return }
        self.server = nil
        port = nil
        if case .failure(let error) = await systemProxy.release() {
            // The lease stays on disk; reconcile at the next start restores it.
            DaemonLog.error("simulator capture: couldn't restore the Mac system proxy: \(error.message)")
        }
        server.stop()
    }

    /// Tells each capture that joined since the proxy started that it now captures.
    private func announce() {
        guard let port else { return }
        for key in Array(members.keys) where members[key]?.live == false {
            members[key]?.live = true
            members[key]?.source.hubDidStart(port: port)
        }
    }

    private func failAll(_ message: String) {
        let failed = members.values.map(\.source)
        members.removeAll()
        routes.removeAll()
        for source in failed { source.hubDidFail(message) }
    }

    private func dropRouteIfUnused(_ deviceID: String) {
        if !members.values.contains(where: { $0.source.device.id == deviceID }) {
            routes.remove(deviceID)
        }
    }

    // MARK: - Events from the proxy

    func deliver(_ transaction: NetworkTransaction, to deviceID: String) {
        for member in members.values where member.live && member.source.device.id == deviceID {
            member.source.hubDidReceive(transaction)
        }
    }

    private func handshake(deviceID: String, verdict: TLSPassthroughPolicy.Verdict, needsSetup: Bool) {
        for key in Array(members.keys) {
            guard let member = members[key], member.source.device.id == deviceID else { continue }
            if case .passthroughAdded(let host) = verdict {
                member.source.hubDidPassThrough(host: host)
            }
            if needsSetup, !member.setupRequested {
                members[key]?.setupRequested = true
                member.source.hubNeedsSetup()
            }
        }
    }
}
