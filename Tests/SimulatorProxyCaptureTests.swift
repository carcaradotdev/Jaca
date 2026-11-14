import XCTest
import Network
@testable import Jaca

/// The simulator capture changes the Mac system proxy, so every test runs against a fake
/// `networksetup` (`FakeNetworkSetup`), a temporary lease directory and a fake attributor.
@MainActor
final class SimulatorProxyCaptureTests: XCTestCase {
    private var directory: URL!
    private var caDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorProxyCaptureTests-\(UUID().uuidString)")
        directory = base.appendingPathComponent("lease")
        caDirectory = base.appendingPathComponent("ca")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        try await super.tearDown()
    }

    private let corp = MacProxySetting(enabled: true, server: "corp", port: 8080)

    private func makeHub(_ mac: FakeNetworkSetup,
                         attribute: @escaping SimulatorProxyHub.Attribute = { _ in nil },
                         origin: OriginRequesting = SimFixedOrigin()) -> SimulatorProxyHub {
        let systemProxy = MacSystemProxy(directory: directory, run: mac.runner, isOwnerAlive: { _ in false },
                                         ownPid: 100, armsTerminationHook: false)
        return SimulatorProxyHub(systemProxy: systemProxy, attribute: attribute, origin: origin)
    }

    private func makeSource(_ udid: String, hub: SimulatorProxyHub) throws -> SimulatorProxyCaptureSource {
        let device = Device(id: udid, platform: .iosSimulator, model: "iPhone 16", state: .booted)
        return SimulatorProxyCaptureSource(device: device, ca: try CertificateAuthority(directory: caDirectory),
                                           intercept: nil, hub: hub)
    }

    // MARK: - Shared proxy and lease

    func test_twoCaptures_shareOneProxy_andOneAcquire() async throws {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": corp])
        let hub = makeHub(mac)
        let a = try makeSource("SIM-A", hub: hub), b = try makeSource("SIM-B", hub: hub)
        let sinkA = SimProxyTestSink(), sinkB = SimProxyTestSink()

        a.start(into: sinkA)
        b.start(into: sinkB)
        await hub.settle()

        let port = try XCTUnwrap(hub.port)
        XCTAssertEqual(sinkA.ports, [port])
        XCTAssertEqual(sinkB.ports, [port])
        XCTAssertEqual(sinkA.statuses.last, "Capturing this device through Jaca's proxy")
        // One acquire: the web and secure web proxy of the one service, set once.
        XCTAssertEqual(mac.setCount, 2)
        XCTAssertEqual(mac.setting("Wi-Fi", .web), MacProxySetting(enabled: true, server: "127.0.0.1", port: port))

        a.stop()
        b.stop()
        await hub.settle()
    }

    func test_lastStop_releasesTheSystemProxy_andStopsTheProxy() async throws {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": corp])
        let hub = makeHub(mac)
        let a = try makeSource("SIM-A", hub: hub), b = try makeSource("SIM-B", hub: hub)
        a.start(into: SimProxyTestSink())
        b.start(into: SimProxyTestSink())
        await hub.settle()
        let port = try XCTUnwrap(hub.port)

        a.stop()
        await hub.settle()
        XCTAssertTrue(hub.isRunning, "one capture still runs")
        XCTAssertEqual(mac.setting("Wi-Fi", .web), MacProxySetting(enabled: true, server: "127.0.0.1", port: port))

        b.stop()
        await hub.settle()
        XCTAssertFalse(hub.isRunning)
        XCTAssertNil(hub.port)
        XCTAssertEqual(mac.setting("Wi-Fi", .web), corp)
        XCTAssertEqual(mac.setting("Wi-Fi", .secureWeb), corp)
        XCTAssertNil(MacSystemProxyLeaseFile.load(from: directory))
    }

    func test_aCaptureAfterTheLastStop_startsAgain() async throws {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": .off])
        let hub = makeHub(mac)
        let a = try makeSource("SIM-A", hub: hub)
        a.start(into: SimProxyTestSink())
        a.stop()
        let sink = SimProxyTestSink()
        a.start(into: sink)
        await hub.settle()
        XCTAssertTrue(hub.isRunning)
        XCTAssertEqual(sink.ports.count, 1)
        a.stop()
        await hub.settle()
        XCTAssertEqual(mac.setting("Wi-Fi", .web).enabled, false)
    }

    func test_failedAcquire_setsAStatus_andStopsCleanly() async throws {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": .off])
        mac.failSetFor = "Wi-Fi"
        let hub = makeHub(mac)
        let a = try makeSource("SIM-A", hub: hub)
        let sink = SimProxyTestSink()

        a.start(into: sink)
        await hub.settle()

        XCTAssertFalse(hub.isRunning)
        XCTAssertEqual(hub.memberCount, 0)
        XCTAssertFalse(a.joined)
        XCTAssertTrue(sink.ports.isEmpty)
        let status = try XCTUnwrap(sink.statuses.last)
        XCTAssertTrue(status.hasPrefix("Couldn’t set the Mac’s system proxy: "), status)
        a.stop()   // a no-op after the failure
        await hub.settle()
        XCTAssertFalse(hub.isRunning)
    }

    func test_noCA_setsTheCertificateStatus_andDoesNotJoin() async {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": .off])
        let hub = makeHub(mac)
        let device = Device(id: "SIM-A", platform: .iosSimulator, model: "iPhone 16", state: .booted)
        let source = SimulatorProxyCaptureSource(device: device, ca: nil, intercept: nil, hub: hub)
        let sink = SimProxyTestSink()
        source.start(into: sink)
        await hub.settle()
        XCTAssertEqual(sink.statuses, ["Couldn’t read Jaca’s certificate. Check ~/.jaca/jacad.log."])
        XCTAssertEqual(mac.setCount, 0)
        XCTAssertEqual(source.interceptCapabilities, [])
        XCTAssertFalse(source.interceptWired)
        XCTAssertEqual(SimulatorProxyCaptureSource.claim, .macSystemProxy)
    }

    // MARK: - Traffic

    func test_aNonSimulatorClient_isRelayedRaw_andProducesNoTransaction() async throws {
        let origin = try SimHTTPStubServer(body: "upstream")
        defer { origin.stop() }
        let mac = FakeNetworkSetup(services: ["Wi-Fi": .off])
        let hub = makeHub(mac, attribute: { _ in nil })
        let a = try makeSource("SIM-A", hub: hub)
        let sink = SimProxyTestSink()
        a.start(into: sink)
        await hub.settle()
        let port = try XCTUnwrap(hub.port)

        let client = SimRawClient(port: port)
        defer { client.stop() }
        client.send("GET http://127.0.0.1:\(origin.port)/raw HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
        let answered = await eventually { client.text.contains("upstream") }
        XCTAssertTrue(answered, "got: \(client.text)")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(sink.transactions.isEmpty)

        a.stop()
        await hub.settle()
    }

    func test_aTransaction_isRoutedToTheCaptureOfItsSimulator() async throws {
        let mac = FakeNetworkSetup(services: ["Wi-Fi": .off])
        // Every client belongs to SIM-B, written in another case.
        let hub = makeHub(mac, attribute: { _ in "sim-b" })
        let a = try makeSource("SIM-A", hub: hub), b = try makeSource("SIM-B", hub: hub)
        let sinkA = SimProxyTestSink(), sinkB = SimProxyTestSink()
        a.start(into: sinkA)
        b.start(into: sinkB)
        await hub.settle()
        let port = try XCTUnwrap(hub.port)

        let client = SimRawClient(port: port)
        defer { client.stop() }
        client.send("GET http://sim.jaca.test/x HTTP/1.1\r\nHost: sim.jaca.test\r\n\r\n")
        let done = await eventually { sinkB.transactions.contains { !$0.isInFlight } }
        XCTAssertTrue(done, "got: \(client.text)")
        XCTAssertTrue(client.text.contains("fixed"), "got: \(client.text)")
        XCTAssertEqual(sinkB.transactions.last?.url, "http://sim.jaca.test/x")
        XCTAssertTrue(sinkA.transactions.isEmpty)

        a.stop()
        b.stop()
        await hub.settle()
    }

    // MARK: - Pure routing

    func test_policy_interceptsOnlyARunningSimulatorOnLoopback() {
        let running: Set<String> = ["ABCD-1234"]
        XCTAssertEqual(SimulatorProxyRouting.policy(remoteHost: "127.0.0.1", udid: "abcd-1234", running: running),
                       .intercept(target: ProxyInterceptTarget(deviceID: "ABCD-1234")))
        XCTAssertEqual(SimulatorProxyRouting.policy(remoteHost: "::1", udid: "ABCD-1234", running: running),
                       .intercept(target: ProxyInterceptTarget(deviceID: "ABCD-1234")))
        XCTAssertEqual(SimulatorProxyRouting.policy(remoteHost: "127.0.0.1", udid: nil, running: running), .relayRaw)
        XCTAssertEqual(SimulatorProxyRouting.policy(remoteHost: "127.0.0.1", udid: "OTHER", running: running), .relayRaw)
        XCTAssertEqual(SimulatorProxyRouting.policy(remoteHost: "192.168.1.5", udid: "ABCD-1234", running: running), .relayRaw)
        XCTAssertEqual(SimulatorProxyRouting.policy(remoteHost: "127.0.0.1", udid: "ABCD-1234", running: []), .relayRaw)
    }

    func test_precheck_needsABootedSimulator() async {
        let device = Device(id: "ABCD-1234", platform: .iosSimulator, model: "iPhone 16", state: .booted)
        let booted = "== Devices ==\n-- iOS 18.0 --\n    iPhone 16 (ABCD-1234) (Booted)\n"
        let ok = await SimulatorProxyCaptureSource.precheck(device: device, listBooted: { booted })
        XCTAssertNil(ok)
        let none = await SimulatorProxyCaptureSource.precheck(device: device, listBooted: { "== Devices ==\n" })
        XCTAssertEqual(none, "iPhone 16 isn’t booted — start the simulator and try again.")
        let failed = await SimulatorProxyCaptureSource.precheck(device: device, listBooted: { nil })
        XCTAssertEqual(failed, "iPhone 16 isn’t booted — start the simulator and try again.")
    }

    func test_routingResolver_usesTheRulesOfTheRequestsSimulator() {
        let routes = SimulatorProxyRoutes()
        let seen = SimBox<[String]>([])
        routes.add("SIM-A", pipeline: InterceptPipeline(resolver: SimRecordingResolver { _ in seen.mutate { $0.append("A") } }))
        routes.add("SIM-B", pipeline: nil)
        let resolver = SimulatorRoutingResolver(routes: routes)

        _ = resolver.resolve(request("SIM-A"), capabilities: .desktopTerminated)
        let (decision, skip) = resolver.resolve(request("SIM-B"), capabilities: .desktopTerminated)
        XCTAssertEqual(seen.value, ["A"])
        XCTAssertNil(decision.ruleID)
        XCTAssertEqual(skip, .noRuleMatched)
    }

    private func request(_ deviceID: String) -> InterceptedRequest {
        InterceptedRequest(id: UUID(), method: "GET", url: "https://example.com/", headers: [], body: nil,
                           transport: .mitmProxy, deviceID: deviceID, appID: nil, startedAt: Date())
    }

    /// Waits up to `timeout` for `condition`, without blocking the main actor.
    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

// MARK: - Helpers

@MainActor
private final class SimProxyTestSink: CaptureSink {
    var transactions: [NetworkTransaction] = []
    var statuses: [String] = []
    var ports: [Int] = []
    var setupRequests = 0

    func capture(didReceive transaction: NetworkTransaction) { transactions.append(transaction) }
    func capture(didChangeStatus status: String?) { if let status { statuses.append(status) } }
    func capture(didBindPort port: Int) { ports.append(port) }
    func captureNeedsSetup() { setupRequests += 1 }
}

private final class SimBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

private struct SimRecordingResolver: InterceptResolving {
    let seen: @Sendable (InterceptedRequest) -> Void
    init(_ seen: @escaping @Sendable (InterceptedRequest) -> Void) { self.seen = seen }
    func resolve(_ request: InterceptedRequest,
                 capabilities: InterceptCapabilities) -> (InterceptDecision, InterceptSkipReason?) {
        seen(request)
        return (.proceed, .noRuleMatched)
    }
}

/// Answers every request with "fixed", without the network.
private struct SimFixedOrigin: OriginRequesting {
    func perform(_ request: InterceptedRequest) async -> InterceptedResponse {
        InterceptedResponse(statusCode: 200, body: Data("fixed".utf8), responseStart: Date(), responseEnd: Date())
    }
}

/// Answers each connection with one fixed HTTP response, then closes it.
private final class SimHTTPStubServer: @unchecked Sendable {
    private let listener: NWListener
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init(body: String) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel() }
}

/// A TCP client that keeps everything it has read as text.
private final class SimRawClient: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var received = Data()

    init(port: Int) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any, using: .tcp)
        connection.start(queue: .global())
        receive()
    }

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: received, as: UTF8.self) }

    func send(_ s: String) { connection.send(content: Data(s.utf8), completion: .contentProcessed { _ in }) }

    func stop() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.lock.lock(); self.received.append(data); self.lock.unlock() }
            if !done, error == nil { self.receive() }
        }
    }
}
