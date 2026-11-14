import Network
import XCTest
@testable import Jaca

/// `CONNECT` tunnels: the target's port is kept, and a tunnel that isn't TLS (a `ws://`
/// WebSocket from Chrome) is relayed to its target as it is. TLS to a host `shouldDecrypt`
/// rejects, and all traffic of a `.relayRaw` client, is relayed too, without a transaction.
final class ProxyTunnelTests: XCTestCase {
    func test_connectTarget_andTunnelURL() {
        XCTAssertTrue(ProxyServer.connectTarget("example.com:443") == ("example.com", 443))
        XCTAssertTrue(ProxyServer.connectTarget("app.local:3000") == ("app.local", 3000))
        XCTAssertTrue(ProxyServer.connectTarget("[::1]:3000") == ("::1", 3000))
        XCTAssertTrue(ProxyServer.connectTarget("example.com") == ("example.com", 443))
        XCTAssertEqual(ProxyServer.tunnelURL(host: "example.com", port: 443, path: "/a?b"), "https://example.com/a?b")
        XCTAssertEqual(ProxyServer.tunnelURL(host: "app.local", port: 3000, path: "/"), "https://app.local:3000/")
        XCTAssertEqual(ProxyServer.tunnelURL(host: "::1", port: 3000, path: "/"), "https://[::1]:3000/")
    }

    func test_aTunnelThatIsNotTLS_isRelayedBothWays() throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jaca-tunnel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let proxy = ProxyServer(port: 0, ca: try CertificateAuthority(directory: dir), bindHost: "127.0.0.1") { _ in }
        try proxy.start()
        defer { proxy.stop() }

        let client = RawClient(port: proxy.boundPort)
        defer { client.stop() }
        client.send("CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n")
        XCTAssertTrue(client.waitFor("200 Connection Established"), "got: \(client.text)")
        client.send("GET /socket HTTP/1.1\r\nUpgrade: websocket\r\n\r\n")
        XCTAssertTrue(client.waitFor("echo:GET /socket"), "got: \(client.text)")
        client.send("second")
        XCTAssertTrue(client.waitFor("echo:second"), "got: \(client.text)")
    }

    // MARK: Passthrough and client policy

    /// The first bytes of a TLS ClientHello record, then a marker the echo shows back.
    private static let clientHello = Data([0x16, 0x03, 0x01, 0x00, 0x05]) + Data("hello".utf8)

    private func makeCA() throws -> (CertificateAuthority, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jaca-tunnel-\(UUID().uuidString)", isDirectory: true)
        return (try CertificateAuthority(directory: dir), dir)
    }

    func test_TLSToAHostThatIsNotDecrypted_isRelayedRaw_withoutATransaction() throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        let (ca, dir) = try makeCA()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = Box<[String]>([])
        let sink = ProxyServerTests.Sink()
        let proxy = ProxyServer(port: 0, ca: ca, bindHost: "127.0.0.1",
                                shouldDecrypt: { host in asked.mutate { $0.append(host) }; return false },
                                onTransaction: { sink.add($0) })
        try proxy.start()
        defer { proxy.stop() }

        let client = RawClient(port: proxy.boundPort)
        defer { client.stop() }
        client.send("CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n")
        XCTAssertTrue(client.waitFor("200 Connection Established"), "got: \(client.text)")
        client.send(Self.clientHello)
        XCTAssertTrue(client.waitFor("echo:\u{16}\u{03}\u{01}\u{00}\u{05}hello"), "got: \(client.text)")
        XCTAssertEqual(asked.value, ["127.0.0.1"])
        XCTAssertTrue(sink.transactions.isEmpty)
    }

    func test_aRelayRawClient_tunnelsTLSRaw_evenWhenTheHostIsDecrypted() throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        let (ca, dir) = try makeCA()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = ProxyServerTests.Sink()
        let proxy = ProxyServer(port: 0, ca: ca, bindHost: "127.0.0.1",
                                clientPolicy: { _ in .relayRaw },
                                onTransaction: { sink.add($0) })
        try proxy.start()
        defer { proxy.stop() }

        let client = RawClient(port: proxy.boundPort)
        defer { client.stop() }
        client.send("CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n")
        XCTAssertTrue(client.waitFor("200 Connection Established"), "got: \(client.text)")
        client.send(Self.clientHello)
        XCTAssertTrue(client.waitFor("echo:\u{16}\u{03}\u{01}\u{00}\u{05}hello"), "got: \(client.text)")
        XCTAssertTrue(sink.transactions.isEmpty)
    }

    func test_aRelayRawClient_forwardsPlainHTTP_withoutRulesOrATransaction() throws {
        let origin = try HTTPStubServer(body: "upstream")
        defer { origin.stop() }
        let (ca, dir) = try makeCA()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = Box<Int>(0)
        let pipeline = InterceptPipeline(resolver: RecordingResolver { _ in resolved.mutate { $0 += 1 } })
        let sink = ProxyServerTests.Sink()
        let proxy = ProxyServer(port: 0, ca: ca, pipeline: pipeline, bindHost: "127.0.0.1",
                                clientPolicy: { _ in .relayRaw },
                                onTransaction: { sink.add($0) })
        try proxy.start()
        defer { proxy.stop() }

        let client = RawClient(port: proxy.boundPort)
        defer { client.stop() }
        client.send("GET http://127.0.0.1:\(origin.port)/raw HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\n\r\n")
        XCTAssertTrue(client.waitFor("upstream"), "got: \(client.text)")
        XCTAssertTrue(client.text.hasPrefix("HTTP/1.1 200"), "got: \(client.text)")
        XCTAssertEqual(resolved.value, 0, "a raw client must not run the override rules")
        XCTAssertTrue(sink.transactions.isEmpty)
    }

    func test_anInterceptClient_isAttributedToItsTarget_andTheHookSeesTheClient() throws {
        let (ca, dir) = try makeCA()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deviceIDs = Box<[String?]>([])
        let infos = Box<[ProxyClientInfo]>([])
        let pipeline = InterceptPipeline(resolver: RecordingResolver { request in deviceIDs.mutate { $0.append(request.deviceID) } },
                                         origin: FixedOrigin())
        let sink = ProxyServerTests.Sink()
        let proxy = ProxyServer(port: 0, ca: ca, pipeline: pipeline,
                                target: ProxyInterceptTarget(deviceID: "server-default"), bindHost: "127.0.0.1",
                                clientPolicy: { info in
                                    infos.mutate { $0.append(info) }
                                    return .intercept(target: ProxyInterceptTarget(deviceID: "SIM-UDID"))
                                },
                                onTransaction: { sink.add($0) })
        try proxy.start()
        defer { proxy.stop() }

        let client = RawClient(port: proxy.boundPort)
        defer { client.stop() }
        client.send("GET http://sim.jaca.test/x HTTP/1.1\r\nHost: sim.jaca.test\r\n\r\n")
        XCTAssertTrue(client.waitFor("fixed"), "got: \(client.text)")
        XCTAssertEqual(deviceIDs.value, ["SIM-UDID"])
        let info = try XCTUnwrap(infos.value.first)
        XCTAssertEqual(info.remoteHost, "127.0.0.1")
        XCTAssertGreaterThan(info.remotePort, 0)
        XCTAssertEqual(info.localPort, proxy.boundPort)
        let deadline = Date().addingTimeInterval(3)
        while sink.transactions.filter({ !$0.isInFlight }).isEmpty, Date() < deadline { usleep(20_000) }
        XCTAssertEqual(sink.transactions.last?.url, "http://sim.jaca.test/x")
    }

    func test_resolvePolicy_withoutAHook_interceptsForTheDefaultTarget() {
        let info = ProxyClientInfo(remoteHost: "127.0.0.1", remotePort: 50000, localPort: 9090)
        let target = ProxyInterceptTarget(deviceID: "emulator-5554")
        XCTAssertEqual(ProxyServer.resolvePolicy(nil, info: info, defaultTarget: target), .intercept(target: target))
        XCTAssertEqual(ProxyServer.resolvePolicy({ _ in .relayRaw }, info: info, defaultTarget: target), .relayRaw)
    }
}

/// A value several threads read and change.
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}

/// Calls `seen` for each request and applies no rule.
private struct RecordingResolver: InterceptResolving {
    let seen: @Sendable (InterceptedRequest) -> Void
    init(_ seen: @escaping @Sendable (InterceptedRequest) -> Void) { self.seen = seen }
    func resolve(_ request: InterceptedRequest,
                 capabilities: InterceptCapabilities) -> (InterceptDecision, InterceptSkipReason?) {
        seen(request)
        return (.proceed, .noRuleMatched)
    }
}

/// Answers every request with "fixed", without the network.
private struct FixedOrigin: OriginRequesting {
    func perform(_ request: InterceptedRequest) async -> InterceptedResponse {
        InterceptedResponse(statusCode: 200, body: Data("fixed".utf8), responseStart: Date(), responseEnd: Date())
    }
}

/// Answers each connection with one fixed HTTP response, then closes it.
private final class HTTPStubServer: @unchecked Sendable {
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

/// Answers every read with "echo:" and what it read.
private final class EchoServer: @unchecked Sendable {
    private let listener: NWListener
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            Self.echo(connection)
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() { listener.cancel() }

    private static func echo(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data, !data.isEmpty {
                connection.send(content: Data("echo:".utf8) + data, completion: .contentProcessed { _ in })
            }
            if done || error != nil { connection.cancel() } else { echo(connection) }
        }
    }
}

/// A TCP client that keeps everything it has read as text.
private final class RawClient: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var received = Data()

    init(port: Int) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        connection.start(queue: .global())
        receive()
    }

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: received, as: UTF8.self) }

    func send(_ s: String) { connection.send(content: Data(s.utf8), completion: .contentProcessed { _ in }) }

    func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }

    func waitFor(_ needle: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if text.contains(needle) { return true }
            usleep(20_000)
        }
        return false
    }

    func stop() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.lock.lock(); self.received.append(data); self.lock.unlock() }
            if !done, error == nil { self.receive() }
        }
    }
}
