import XCTest
@testable import Jaca

private struct OneDeviceProvider: DeviceProvider {
    let platform: DevicePlatform
    let devices: [Device]
    func deviceStream() -> AsyncStream<[Device]> {
        AsyncStream { c in c.yield(devices) }
    }
}

/// What a `CLIRunner` printed.
private final class Printed: @unchecked Sendable {
    var out: [String] = []
    var err: [String] = []
    var outText: String { out.joined(separator: "\n") }
    var errText: String { err.joined(separator: "\n") }
}

/// The daemon methods behind `jaca`, and `jaca` itself against an in-process daemon. Nothing here
/// touches the user's data: the socket, the rule library and the body cache are temporary
/// directories (`JACA_DAEMON_DIR` through `TestDaemon`, `JACA_OVERRIDES_DIR`), and there is no
/// log history store.
@MainActor
final class DaemonCLITests: XCTestCase {
    private var dir: URL!
    private var daemon: TestDaemon!
    private var captures: NetworkArea.Captures!
    private var overrides: OverridesEngine!
    private var logs: LogsArea.Registry!
    private var logSource: ScriptedLogSource!
    private var modeStore: NetworkModeStore!
    private var modeController: NetworkModeController!

    private let pixel = Device(id: "emu-1", platform: .android, model: "Pixel", state: .connected)
    private let phone = Device(id: "sim-1", platform: .iosSimulator, model: "iPhone", state: .booted)

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cli-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("JACA_OVERRIDES_DIR", dir.appendingPathComponent("overrides").path, 1)

        daemon = try TestDaemon()
        captures = NetworkArea.Captures(bus: daemon.server.bus,
                                        bodyCache: NetworkBodyCache(directory: dir.appendingPathComponent("bodies")),
                                        bodiesInMemory: 2)
        overrides = OverridesArea.install(on: daemon.server, captures: captures)
        // The mode lives in memory, so `jaca net mode mitm` never writes the user's setting.
        modeStore = .memory(.agentHTTPSDebugging)
        modeController = NetworkModeController(captures: captures, bus: daemon.server.bus, store: modeStore, settle: {})
        NetworkArea.install(on: daemon.server, captures: captures, controller: modeController)
        let source = ScriptedLogSource()
        logSource = source
        logs = LogsArea.Registry(bus: daemon.server.bus, history: nil, replayCap: 1_000) { id, _, device, package, seqStart in
            LogStreamEngine(id: id, device: device, adbURL: nil, package: package, seqStart: seqStart,
                            makeSource: { _ in source }, prettifyEnabled: { false })
        }
        LogsArea.install(on: daemon.server, registry: logs)
        let devices = [pixel, phone]
        DevicesArea.install(on: daemon.server, engine: DevicesEngine(defaults: .standard) { _ in
            [OneDeviceProvider(platform: .android, devices: [devices[0]]),
             OneDeviceProvider(platform: .iosSimulator, devices: [devices[1]])]
        })
    }

    override func tearDown() async throws {
        modeController = nil
        daemon = nil
        unsetenv("JACA_OVERRIDES_DIR")
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), _ cond: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !cond() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition not met in time") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Fixtures

    private func txn(_ id: String, _ method: String, _ url: String, status: Int?, body: String? = nil,
                     at offset: TimeInterval, error: String? = nil) -> NetworkTransaction {
        let components = URLComponents(string: url)
        var t = NetworkTransaction(id: UUID(uuidString: id)!, method: method, url: url, host: components?.host ?? "",
                                   scheme: components?.scheme ?? "https",
                                   requestHeaders: [HeaderPair(name: "Authorization", value: "Bearer secret-token"),
                                                    HeaderPair(name: "Accept", value: "application/json")],
                                   startedAt: Date(timeIntervalSince1970: 1_790_000_000 + offset))
        t.statusCode = status
        t.error = error
        if let body {
            t.responseHeaders = [HeaderPair(name: "Content-Type", value: "application/json"),
                                 HeaderPair(name: "Set-Cookie", value: "sid=abc123"),
                                 HeaderPair(name: "Content-Length", value: "\(body.utf8.count)")]
            t.responseContentType = "application/json"
            t.responseBody = Data(body.utf8)
            t.responseBytes = body.utf8.count
        }
        if status != nil || error != nil { t.finishedAt = t.startedAt.addingTimeInterval(0.25) }
        return t
    }

    private let failingID = "3FA2B1C0-0000-4000-8000-000000000001"
    private let okID = "3FA2FFFF-0000-4000-8000-000000000002"

    /// A capture on the Pixel with five requests (one 500, one transport error, one in flight) and
    /// one on the iPhone with a single 404. `bodiesInMemory` is 2, so the oldest bodies are on disk.
    @discardableResult
    private func openCaptures() async throws -> (pixel: UUID, phone: UUID) {
        let a = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")!
        let b = UUID(uuidString: "BBBBBBBB-0000-4000-8000-000000000002")!
        _ = captures.open(NetworkArea.OpenParams(id: a, device: pixel, sourceID: nil, package: nil, autoStart: false))
        _ = captures.open(NetworkArea.OpenParams(id: b, device: phone, sourceID: nil, package: nil, autoStart: false))
        let first = try XCTUnwrap(captures.sessions[a]?.engine), second = try XCTUnwrap(captures.sessions[b]?.engine)
        first.capture(didReceive: txn(failingID, "POST", "https://api.example.com/v1/orders?retry=1", status: 500,
                                      body: #"{"error":"boom"}"#, at: 0))
        first.capture(didReceive: txn(okID, "GET", "https://api.example.com/v1/users", status: 200, body: #"{"users":[]}"#, at: 1))
        first.capture(didReceive: txn("5E000000-0000-4000-8000-000000000003", "GET", "https://cdn.example.net/logo.png",
                                      status: nil, at: 2, error: "timed out"))
        first.capture(didReceive: txn("6F000000-0000-4000-8000-000000000004", "GET", "https://api.example.com/v1/slow", status: nil, at: 3))
        first.capture(didReceive: txn("7A000000-0000-4000-8000-000000000005", "GET", "https://api.example.com/v1/ok", status: 204, at: 4))
        second.capture(didReceive: txn("8B000000-0000-4000-8000-000000000006", "GET", "https://other.example.org/missing",
                                       status: 404, body: #"{"error":"nope"}"#, at: 5))
        try await waitUntil {
            self.captures.sessions[a]?.transactions.count == 5 && self.captures.sessions[b]?.transactions.count == 1
        }
        // The spill of the oldest rows is a task: wait for it so body reads go through the cache.
        try await waitUntil { self.captures.sessions[a]?.transactions.first?.bodiesEvicted == true }
        return (a, b)
    }

    @discardableResult
    private func openLogSession(name: String = "Sim logs") async throws -> UUID {
        let info = try logs.open(LogsArea.OpenParams(id: nil, device: phone, package: nil, displayName: name, autoStart: true, seqStart: nil))
        try await waitUntil { self.logSource.isStreaming }
        logSource.emit("boot", level: .info)
        logSource.emit("Request timeout after 30s", tag: "Http", level: .error)
        logSource.emit("retrying", level: .warn)
        logSource.emit("Unhandled exception", tag: "Crash", level: .fatal)
        try await waitUntil { self.logs.sessions[info.id]?.replay.count == 4 }
        return info.id
    }

    private func run(_ line: String, json: Bool = false, raw: Bool = false, file: [String: Data] = [:]) async throws -> (status: Int32, printed: Printed) {
        let invocation = CLIParser.parse(line.split(separator: " ").map(String.init))
        let printed = Printed()
        let client = try await daemon.client()
        var runner = CLIRunner(client: client, json: json || invocation.json, raw: raw || invocation.raw,
                               out: { printed.out.append($0) }, err: { printed.err.append($0) })
        runner.readFile = { path in
            guard let data = file[path] else { throw CocoaError(.fileReadNoSuchFile) }
            return data
        }
        let status = await runner.run(invocation.command)
        client.close()
        return (status, printed)
    }

    private func json(_ printed: Printed) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(printed.outText.utf8), options: [.fragmentsAllowed])
    }

    // MARK: - network.list / search / transaction

    func test_networkList_reportsEveryOpenCapture() async throws {
        let ids = try await openCaptures()
        let client = try await daemon.client()
        let sessions: [NetworkArea.Session] = try await client.call("network.list")
        XCTAssertEqual(sessions.map(\.id), [ids.pixel, ids.phone])
        XCTAssertEqual(sessions.map(\.name), ["Pixel", "iPhone"])
        XCTAssertEqual(sessions.map(\.transactionCount), [5, 1])
        XCTAssertEqual(sessions[0].device, pixel)
    }

    func test_networkSearch_filtersAndReturnsCompactRows() async throws {
        let ids = try await openCaptures()
        let client = try await daemon.client()
        func search(_ p: NetworkArea.SearchParams) async throws -> [NetworkArea.Row] { try await client.call("network.search", p) }
        func params(id: UUID? = nil, host: String? = nil, method: String? = nil, status: [NetworkStatusRange]? = nil,
                    failed: Bool? = nil, idPrefix: String? = nil, limit: Int? = nil) -> NetworkArea.SearchParams {
            .init(id: id, host: host, method: method, status: status, failed: failed, idPrefix: idPrefix, limit: limit)
        }

        let all = try await search(params())
        XCTAssertEqual(all.count, 6, "every capture, oldest first")
        XCTAssertEqual(all.map(\.startedAt), all.map(\.startedAt).sorted())
        XCTAssertEqual(all.last?.session, ids.phone)

        let failed = try await search(params(failed: true))
        XCTAssertEqual(failed.map(\.statusCode), [500, nil, 404])
        XCTAssertEqual(failed[1].error, "timed out")

        let serverErrors = try await search(params(id: ids.pixel, status: [NetworkStatusRange(min: 500, max: 599)]))
        XCTAssertEqual(serverErrors.map(\.id.uuidString), [failingID])
        let cdn = try await search(params(host: "CDN"))
        XCTAssertEqual(cdn.map(\.host), ["cdn.example.net"])
        let posts = try await search(params(method: "post"))
        XCTAssertEqual(posts.count, 1)
        let prefixed = try await search(params(idPrefix: "3fa2"))
        XCTAssertEqual(prefixed.count, 2)
        let newest = try await search(params(id: ids.pixel, limit: 2))
        XCTAssertEqual(newest.map(\.url), ["https://api.example.com/v1/slow", "https://api.example.com/v1/ok"], "the newest two")
        let clamped = try await search(params(limit: -4))
        XCTAssertEqual(clamped.count, 1, "a limit below one is one")

        let row = try XCTUnwrap(failed.first)
        XCTAssertEqual(row.durationMs, 250)
        XCTAssertEqual(row.method, "POST")
        // Compact: the wire row has no headers and no bodies.
        let line = try await client.callRaw("network.search", paramsJSON: Data(#"{"failed":true}"#.utf8))
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertFalse(text.contains("Headers") || text.contains("Body") || text.contains("secret-token"), text)

        do {
            _ = try await search(params(id: UUID()))
            XCTFail("an unknown capture is an error")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.failedCode)
            XCTAssertTrue(error.message.hasPrefix("No network capture "))
        }
    }

    func test_networkTransaction_returnsHeadersAndSpilledBodies() async throws {
        let ids = try await openCaptures()
        let client = try await daemon.client()
        let found: NetworkTransaction? = try await client.call(
            "network.transaction", NetworkArea.BodyParams(id: ids.pixel, transaction: UUID(uuidString: failingID)!))
        let txn = try XCTUnwrap(found)
        XCTAssertEqual(txn.responseBody, Data(#"{"error":"boom"}"#.utf8), "read back from the disk cache")
        XCTAssertFalse(txn.bodiesEvicted)
        XCTAssertEqual(txn.requestHeaders.first?.name, "Authorization")

        let unknown: NetworkTransaction? = try await client.call(
            "network.transaction", NetworkArea.BodyParams(id: ids.pixel, transaction: UUID()))
        XCTAssertNil(unknown)
        let closed: NetworkTransaction? = try await client.call(
            "network.transaction", NetworkArea.BodyParams(id: UUID(), transaction: UUID(uuidString: failingID)!))
        XCTAssertNil(closed)
    }

    /// Rows from a daemon that sends less (or more) than this build knows still decode.
    func test_networkRowAndSession_decodeTolerantly() throws {
        let row = try JSONDecoder.daemon.decode(NetworkArea.Row.self, from: Data(
            #"{"id":"3FA2B1C0-0000-4000-8000-000000000001","session":"AAAAAAAA-0000-4000-8000-000000000001","statusCode":"x","later":1}"#.utf8))
        XCTAssertEqual(row.method, "")
        XCTAssertNil(row.statusCode)
        XCTAssertEqual(row.responseBytes, 0)
        let session = try JSONDecoder.daemon.decode(NetworkArea.Session.self, from: Data(
            #"{"id":"AAAAAAAA-0000-4000-8000-000000000001","device":{"id":"emu-1","model":"Pixel"}}"#.utf8))
        XCTAssertEqual(session.name, "Pixel")
        XCTAssertEqual(session.transactionCount, 0)
        XCTAssertFalse(session.state.isRunning)
    }

    // MARK: - logs.search

    func test_logsSearch_filtersInTheDaemon() async throws {
        let id = try await openLogSession()
        let client = try await daemon.client()
        func search(grep: String? = nil, minLevel: LogLevel? = nil, since: Date? = nil, limit: Int? = nil) async throws -> [String] {
            try await client.call("logs.search", LogsArea.SearchParams(id: id, grep: grep, minLevel: minLevel, since: since, limit: limit),
                                  as: [LogLine].self).map(\.message)
        }
        let all = try await search()
        XCTAssertEqual(all, ["boot", "Request timeout after 30s", "retrying", "Unhandled exception"])
        let errors = try await search(minLevel: .error)
        XCTAssertEqual(errors, ["Request timeout after 30s", "Unhandled exception"])
        let timeouts = try await search(grep: "time.?out")
        XCTAssertEqual(timeouts, ["Request timeout after 30s"])
        let byTag = try await search(grep: "crash")
        XCTAssertEqual(byTag, ["Unhandled exception"], "the tag matches")
        let newest = try await search(limit: 2)
        XCTAssertEqual(newest, ["retrying", "Unhandled exception"])
        let later = try await search(since: Date().addingTimeInterval(60))
        XCTAssertEqual(later, [])

        do {
            _ = try await client.call("logs.search", LogsArea.SearchParams(id: UUID(), grep: nil, minLevel: nil, since: nil, limit: nil),
                                      as: [LogLine].self)
            XCTFail("an unknown session is an error")
        } catch let error as RPCError {
            XCTAssertTrue(error.message.hasPrefix("No log session "))
        }
    }

    // MARK: - devices.list

    func test_devicesList_runsDiscoveryWhenNobodyWatches() async throws {
        let client = try await daemon.client()
        let devices: [Device] = try await client.call("devices.list")
        XCTAssertEqual(devices.map(\.id), ["emu-1", "sim-1"])
    }

    // MARK: - overrides.createFromTransaction

    func test_createFromTransaction_seedsAndSavesAnEnabledRule() async throws {
        let ids = try await openCaptures()
        let client = try await daemon.client()
        let created: OverridesArea.Created? = try await client.call(
            "overrides.createFromTransaction",
            OverridesArea.FromTransactionParams(id: ids.pixel, transaction: UUID(uuidString: failingID)!,
                                                name: nil, statusCode: nil, body: nil, enabled: nil))
        let rule = try XCTUnwrap(created?.rule)
        XCTAssertEqual(rule.name, "POST orders")
        XCTAssertTrue(rule.enabled, "a new rule is enabled")
        XCTAssertEqual(rule.matcher.pattern, "https://api.example.com/v1/orders", "the query is dropped")
        XCTAssertEqual(rule.matcher.methods, ["POST"])
        XCTAssertEqual(rule.routedHosts, ["api.example.com"])
        guard case .respond(let spec) = rule.action else { return XCTFail("a seeded rule answers") }
        XCTAssertEqual(spec.statusCode, 500)
        XCTAssertFalse(spec.headers.contains { $0.name == "Content-Length" }, "framing headers are recomputed")
        guard case .inline(let body) = spec.body else { return XCTFail("a small body is inline: \(spec.body)") }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String], ["error": "boom"],
                       "the captured body, read back from the disk cache")
        XCTAssertNil(created?.warning)

        XCTAssertEqual(overrides.state.rules.map(\.id), [rule.id], "in the engine the captures are armed from")
        XCTAssertEqual(OverrideRuleStore.load().map(\.id), [rule.id], "and in rules.json")
        XCTAssertTrue(OverrideRuleStore.rulesURL.path.hasPrefix(dir.path), "the temporary library, not the user's")
    }

    func test_createFromTransaction_appliesTheReplacements() async throws {
        let ids = try await openCaptures()
        let client = try await daemon.client()
        let created: OverridesArea.Created? = try await client.call(
            "overrides.createFromTransaction",
            OverridesArea.FromTransactionParams(id: ids.pixel, transaction: UUID(uuidString: okID)!, name: "Empty users",
                                                statusCode: 503, body: Data("{\"down\":true}".utf8), enabled: false))
        let rule = try XCTUnwrap(created?.rule)
        XCTAssertEqual(rule.name, "Empty users")
        XCTAssertFalse(rule.enabled)
        guard case .respond(let spec) = rule.action else { return XCTFail("a seeded rule answers") }
        XCTAssertEqual(spec.statusCode, 503)
        XCTAssertEqual(spec.body, .inline("{\"down\":true}"))
    }

    func test_createFromTransaction_unknownTransactionIsNull_andSavesNothing() async throws {
        let ids = try await openCaptures()
        let client = try await daemon.client()
        for (capture, transaction) in [(ids.pixel, UUID()), (UUID(), UUID(uuidString: failingID)!)] {
            let created: OverridesArea.Created? = try await client.call(
                "overrides.createFromTransaction",
                OverridesArea.FromTransactionParams(id: capture, transaction: transaction, name: nil, statusCode: nil, body: nil, enabled: nil))
            XCTAssertNil(created)
        }
        XCTAssertTrue(overrides.state.rules.isEmpty)
    }

    /// The rule reaches the app: its model mirrors `overrides.state` when capture runs in the daemon.
    func test_createFromTransaction_showsUpInTheAppModel() async throws {
        let ids = try await openCaptures()
        let connector = DaemonConnector(paths: daemon.paths, executable: nil, enabledAreas: [.network])
        let model = OverridesModel(daemon: connector, inDaemon: true)
        let client = try await daemon.client()
        let created: OverridesArea.Created? = try await client.call(
            "overrides.createFromTransaction",
            OverridesArea.FromTransactionParams(id: ids.pixel, transaction: UUID(uuidString: failingID)!,
                                                name: nil, statusCode: nil, body: nil, enabled: nil))
        let id = try XCTUnwrap(created?.rule.id)
        try await waitUntil { model.rules.contains { $0.id == id } }
    }

    // MARK: - jaca, end to end

    /// The flow from the task: list sessions, find the failing request, read its body, make an
    /// override from it, see it in the list.
    func test_jaca_findAFailingRequestAndOverrideIt() async throws {
        try await openCaptures()

        let sessions = try await run("net list")
        XCTAssertEqual(sessions.status, 0)
        XCTAssertEqual(sessions.printed.outText, """
        id        name    deviceID  package  isRunning  transactionCount  statusMessage
        AAAAAAAA  Pixel   emu-1              false      5
        BBBBBBBB  iPhone  sim-1              false      1
        """)

        let failing = try await run("net requests pixel --failed")
        XCTAssertEqual(failing.status, 0)
        let rows = failing.printed.outText.split(separator: "\n").map(String.init)
        XCTAssertEqual(rows.count, 3, failing.printed.outText)
        XCTAssertTrue(rows[0].hasPrefix("id        startedAt  method  statusCode  durationMs  responseBytes  url"), rows[0])
        XCTAssertTrue(rows[1].hasPrefix("3FA2B1C0  "), rows[1])
        XCTAssertTrue(rows[1].contains("POST    500         250         16             https://api.example.com/v1/orders?retry=1"), rows[1])
        XCTAssertTrue(rows[2].contains("https://cdn.example.net/logo.png") && rows[2].hasSuffix("  timed out"), rows[2])

        let shown = try await run("net show 3fa2b")
        XCTAssertEqual(shown.status, 0)
        XCTAssertTrue(shown.printed.outText.contains("statusCode: 500"))
        XCTAssertTrue(shown.printed.outText.contains("responseBody:\n{\"error\":\"boom\"}"), shown.printed.outText)
        XCTAssertFalse(shown.printed.outText.contains("secret-token"), "Authorization is redacted")
        XCTAssertFalse(shown.printed.outText.contains("sid=abc123"), "Set-Cookie is redacted")
        XCTAssertTrue(shown.printed.outText.contains("Accept: application/json"))

        let added = try await run("overrides add --from 3fa2b")
        XCTAssertEqual(added.status, 0, added.printed.errText)
        let rule = try XCTUnwrap(overrides.state.rules.first)
        XCTAssertEqual(added.printed.outText, """
        id        enabled  hitCount  action   statusCode  methods  group  pattern                            name
        \(rule.id.uuidString.prefix(8))  true     0         respond  500         POST            https://api.example.com/v1/orders  POST orders
        """)

        let listed = try await run("overrides list")
        XCTAssertEqual(listed.printed.out.first, "masterEnabled: \(overrides.state.masterEnabled)")
        XCTAssertTrue(listed.printed.outText.contains("POST orders"))
    }

    func test_jaca_theSameFlowAsJSON() async throws {
        let ids = try await openCaptures()

        let listedSessions = try await run("net list --json")
        let sessions = try XCTUnwrap(try json(listedSessions.printed) as? [[String: Any]])
        XCTAssertEqual(sessions.map { $0["id"] as? String }, [ids.pixel.uuidString, ids.phone.uuidString])
        XCTAssertEqual(Set(sessions[0].keys), ["id", "name", "deviceID", "platform", "isRunning", "transactionCount"])

        let searched = try await run("net requests --failed --status 5xx --json")
        let failing = try XCTUnwrap(try json(searched.printed) as? [[String: Any]])
        XCTAssertEqual(failing.count, 1)
        XCTAssertEqual(Set(failing[0].keys), ["id", "session", "method", "url", "host", "statusCode", "startedAt",
                                              "durationMs", "requestBytes", "responseBytes"])
        let requestID = try XCTUnwrap(failing[0]["id"] as? String)
        XCTAssertEqual(requestID, failingID)

        let showed = try await run("net show \(requestID) --json")
        let shown = try XCTUnwrap(try json(showed.printed) as? [String: Any])
        XCTAssertEqual(shown["responseBody"] as? String, #"{"error":"boom"}"#)
        XCTAssertEqual(shown["session"] as? String, ids.pixel.uuidString)
        let requestHeaders = try XCTUnwrap(shown["requestHeaders"] as? [[String: Any]])
        XCTAssertEqual(requestHeaders.first { $0["name"] as? String == "Authorization" }?["redacted"] as? Bool, true)
        XCTAssertFalse(showed.printed.outText.contains("secret-token"))

        let created = try await run("overrides add --from \(requestID) --json")
        let added = try XCTUnwrap(try json(created.printed) as? [[String: Any]])
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(Set(added[0].keys), ["id", "name", "enabled", "pattern", "methods", "action", "statusCode", "hitCount", "rule"])
        XCTAssertEqual(added[0]["pattern"] as? String, "https://api.example.com/v1/orders")
        XCTAssertEqual(added[0]["enabled"] as? Bool, true)
        XCTAssertEqual((added[0]["rule"] as? [String: Any])?["id"] as? String, added[0]["id"] as? String)

        let rules = try await run("overrides list --json")
        let listed = try XCTUnwrap(try json(rules.printed) as? [String: Any])
        XCTAssertEqual(Set(listed.keys), ["masterEnabled", "groups", "rules"])
        XCTAssertEqual((listed["rules"] as? [[String: Any]])?.first?["id"] as? String, added[0]["id"] as? String)
    }

    /// `--generalize` puts the rule's path on any base URL while keeping the device's host
    /// routed; the same rewrite applies to a rule that already exists.
    func test_jaca_generalize_onAddAndOnAnExistingRule() async throws {
        try await openCaptures()
        let added = try await run("overrides add --from 3fa2b --generalize --json")
        XCTAssertEqual(added.status, 0, added.printed.errText)
        let rows = try XCTUnwrap(try json(added.printed) as? [[String: Any]])
        XCTAssertEqual(rows.first?["pattern"] as? String, "**/v1/orders")
        let generalized = try XCTUnwrap(overrides.state.rules.first)
        XCTAssertEqual(generalized.routedHosts, ["api.example.com"], "the device still routes the captured host")

        let plain = try await run("overrides add --from 3fa2f --name Users")
        XCTAssertEqual(plain.status, 0, plain.printed.errText)
        XCTAssertEqual(overrides.state.rules.last?.matcher.pattern, "https://api.example.com/v1/users")

        let rewritten = try await run("overrides generalize users")
        XCTAssertEqual(rewritten.status, 0, rewritten.printed.errText)
        let users = try XCTUnwrap(overrides.state.rules.last)
        XCTAssertEqual(users.matcher.pattern, "**/v1/users")
        XCTAssertEqual(users.routedHosts, ["api.example.com"])
        XCTAssertTrue(rewritten.printed.outText.contains("**/v1/users"), rewritten.printed.outText)
        XCTAssertEqual(overrides.state.rules.count, 2, "generalize replaces the rule, it does not add one")
    }

    /// Groups from the command line: make one, put a rule in it, turn it off, list it, delete it.
    func test_jaca_groups() async throws {
        try await openCaptures()
        let added = try await run("overrides add --from 3fa2b --name Orders")
        XCTAssertEqual(added.status, 0)
        let made = try await run("overrides mkgroup Deals --json")
        XCTAssertEqual(made.status, 0, made.printed.errText)
        XCTAssertEqual((try json(made.printed) as? [[String: Any]])?.first?["name"] as? String, "Deals")
        let deals = try XCTUnwrap(overrides.state.groups.first)

        let grouped = try await run("overrides group orders deals")
        XCTAssertEqual(grouped.status, 0, grouped.printed.errText)
        XCTAssertEqual(overrides.state.rules.first?.groupID, deals.id)
        XCTAssertTrue(grouped.printed.outText.contains("Deals"), grouped.printed.outText)

        let disabled = try await run("overrides disable --group deals")
        XCTAssertEqual(disabled.status, 0)
        XCTAssertEqual(overrides.state.groups.first?.enabled, false)
        XCTAssertTrue(overrides.compiled.rules.isEmpty, "the group is off")

        let listed = try await run("overrides groups --json")
        let row = try XCTUnwrap((try json(listed.printed) as? [[String: Any]])?.first)
        XCTAssertEqual(row["rules"] as? Int, 1)
        XCTAssertEqual(row["enabled"] as? Bool, false)

        let ungrouped = try await run("overrides ungroup orders")
        XCTAssertEqual(ungrouped.status, 0)
        XCTAssertNil(overrides.state.rules.first?.groupID)
        let removed = try await run("overrides rmgroup deals")
        XCTAssertEqual(removed.status, 0)
        XCTAssertEqual(overrides.state.groups, [])
        let missing = try await run("overrides group orders nope")
        XCTAssertEqual(missing.status, 1, "no such group")
    }

    func test_jaca_rawShowsCredentials() async throws {
        try await openCaptures()
        let shown = try await run("net show 3fa2b --raw")
        XCTAssertTrue(shown.printed.outText.contains("Authorization: Bearer secret-token"))
        XCTAssertTrue(shown.printed.outText.contains("Set-Cookie: sid=abc123"))
    }

    func test_jaca_addWithReplacements_andToggleAndRemove() async throws {
        try await openCaptures()
        let added = try await run("overrides add --from 3fa2f --name Down --status 503 --body-file body.json --disabled",
                                  file: ["body.json": Data("{\"down\":true}".utf8)])
        XCTAssertEqual(added.status, 0, added.printed.errText)
        var rule = try XCTUnwrap(overrides.state.rules.first)
        XCTAssertEqual(rule.name, "Down")
        XCTAssertFalse(rule.enabled)
        guard case .respond(let spec) = rule.action else { return XCTFail("a seeded rule answers") }
        XCTAssertEqual(spec.statusCode, 503)
        XCTAssertEqual(spec.body, .inline("{\"down\":true}"))

        let enabled = try await run("overrides enable down")
        XCTAssertEqual(enabled.status, 0)
        rule = try XCTUnwrap(overrides.state.rules.first)
        XCTAssertTrue(rule.enabled, "by name, any case")
        XCTAssertTrue(enabled.printed.outText.contains("  true  "), enabled.printed.outText)

        let disabled = try await run("overrides disable \(rule.id.uuidString.prefix(6).lowercased())")
        XCTAssertEqual(disabled.status, 0)
        XCTAssertEqual(overrides.state.rules.first?.enabled, false, "by id prefix")

        let removed = try await run("overrides rm Down")
        XCTAssertEqual(removed.status, 0)
        XCTAssertTrue(removed.printed.outText.contains("Down"), "prints what was removed")
        XCTAssertTrue(overrides.state.rules.isEmpty)
        XCTAssertEqual(OverrideRuleStore.load().count, 0)
    }

    func test_jaca_aBodyFileThatCannotBeRead_createsNothing() async throws {
        try await openCaptures()
        let added = try await run("overrides add --from 3fa2f --body-file missing.json")
        XCTAssertEqual(added.status, 1)
        XCTAssertTrue(added.printed.errText.hasPrefix("jaca: "))
        XCTAssertTrue(added.printed.out.isEmpty)
        XCTAssertTrue(overrides.state.rules.isEmpty)
    }

    /// An argument that fits several things lists them on stderr and changes nothing.
    func test_jaca_ambiguousAndUnknownArguments() async throws {
        try await openCaptures()

        let ambiguous = try await run("net show 3fa2")
        XCTAssertEqual(ambiguous.status, 1)
        XCTAssertTrue(ambiguous.printed.out.isEmpty)
        let candidates = ambiguous.printed.errText.split(separator: "\n")
        XCTAssertEqual(candidates.count, 3, "the header and the two requests that fit")
        XCTAssertTrue(candidates[1].hasPrefix("3FA2B1C0") && candidates[2].hasPrefix("3FA2FFFF"))

        let ambiguousJSON = try await run("overrides add --from 3fa2 --json")
        XCTAssertEqual(ambiguousJSON.status, 1)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(ambiguousJSON.printed.errText.utf8)) as? [Any])?.count, 2)
        XCTAssertTrue(overrides.state.rules.isEmpty, "nothing was created")

        let unknownRequest = try await run("net show ffff")
        XCTAssertEqual(unknownRequest.status, 1)
        XCTAssertEqual(unknownRequest.printed.errText, NetworkArea.Row.header.joined(separator: "  "), "no request fits: the empty table")

        let unknownSession = try await run("net requests nexus")
        XCTAssertEqual(unknownSession.status, 1)
        XCTAssertEqual(unknownSession.printed.errText, "jaca: No network capture nexus.")

        let unknownRule = try await run("overrides rm nothing")
        XCTAssertEqual(unknownRule.status, 1)
        XCTAssertEqual(unknownRule.printed.errText, CLIRule.header.joined(separator: "  "))

        let unknownLogs = try await run("logs tail nexus")
        XCTAssertEqual(unknownLogs.status, 1)
        XCTAssertEqual(unknownLogs.printed.errText, "jaca: No log session nexus.")
    }

    func test_jaca_devicesAndLogs() async throws {
        let id = try await openLogSession()

        let devices = try await run("devices")
        XCTAssertEqual(devices.printed.outText, """
        id     platform      state      model
        emu-1  android       connected  Pixel
        sim-1  iosSimulator  booted     iPhone
        """)

        let sessions = try await run("logs list")
        let rows = sessions.printed.outText.split(separator: "\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[1].hasPrefix("\(id.uuidString.prefix(8))  Sim logs  sim-1"), String(rows[1]))

        // One session is open, so it needs no name.
        let errors = try await run("logs tail --level error")
        XCTAssertEqual(errors.status, 0)
        XCTAssertEqual(errors.printed.out.count, 2)
        XCTAssertTrue(errors.printed.out[0].hasSuffix("Error Http  Request timeout after 30s"), errors.printed.out[0])
        XCTAssertTrue(errors.printed.out[1].hasSuffix("Fatal Crash  Unhandled exception"), errors.printed.out[1])

        let named = try await run("logs tail sim-1 --grep time.?out -n 5 --json")
        let lines = try XCTUnwrap(try json(named.printed) as? [[String: Any]])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["level"] as? String, "error")
        XCTAssertEqual(lines[0]["message"] as? String, "Request timeout after 30s")
        XCTAssertEqual(Set(lines[0].keys), ["seq", "timestamp", "level", "tag", "pid", "message", "marker"])

        let later = try await run("logs tail --since 2030-01-01T00:00:00Z")
        XCTAssertEqual(later.printed.out, [])
    }

    func test_jaca_followPrintsNewMatchingLines() async throws {
        try await openLogSession()
        let printed = Printed()
        let client = try await daemon.client()
        let runner = CLIRunner(client: client, out: { printed.out.append($0) }, err: { printed.err.append($0) })
        let following = Task { @MainActor in
            await runner.run(.logsTail(session: nil, grep: nil, minLevel: .error, since: nil, count: 1, follow: true))
        }
        try await waitUntil { printed.out.count == 1 }                // the tail: the newest error
        logSource.emit("just info", level: .info)
        logSource.emit("another failure", level: .error)
        try await waitUntil { printed.out.count == 2 }
        XCTAssertTrue(printed.out[1].hasSuffix("another failure"))
        XCTAssertFalse(printed.outText.contains("just info"))
        // Following ends with the connection.
        client.close()
        let status = await following.value
        XCTAssertEqual(status, 1)
    }

    func test_jaca_helpDescribesTheMethodsBehindACommand() async throws {
        let help = try await run("overrides add --help")
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.printed.outText.contains("overrides.createFromTransaction"), help.printed.outText)
        XCTAssertTrue(help.printed.outText.contains("\n    transaction: uuid\n"))
        XCTAssertTrue(help.printed.outText.contains("\"glob\" | \"regex\""), "the shape of a rule")

        let described = try await run("net requests --help --json")
        let asJSON = try XCTUnwrap(try json(described.printed) as? [[String: Any]])
        XCTAssertEqual(asJSON.map { $0["name"] as? String }, ["network.search"])
        XCTAssertNotNil(asJSON[0]["params"])
    }

    // MARK: - Network mode and CA install

    func test_jaca_netMode_printsAndSwitchesTheMode() async throws {
        let before = try await run("net mode")
        XCTAssertEqual(before.status, 0, before.printed.errText)
        XCTAssertEqual(before.printed.outText, "mode\nagent")

        let switched = try await run("net mode mitm")
        XCTAssertEqual(switched.status, 0, switched.printed.errText)
        XCTAssertEqual(switched.printed.outText, "mode\nmitm")
        XCTAssertEqual(modeController.mode, .mitmHTTPSDebugging)
        XCTAssertEqual(modeStore.read(), .mitmHTTPSDebugging)

        let asJSON = try await run("net mode --json")
        XCTAssertEqual(asJSON.status, 0, asJSON.printed.errText)
        XCTAssertEqual(asJSON.printed.outText, #"{"mode":"mitm"}"#)

        let back = try await run("net mode agent --json")
        XCTAssertEqual(back.printed.outText, #"{"mode":"agent"}"#)
        XCTAssertEqual(modeStore.read(), .agentHTTPSDebugging)
    }

    func test_jaca_netInstallCA_runsTheInstallForThePickedCapture() async throws {
        try await openCaptures()
        let caDir = dir.appendingPathComponent("ca")
        let ca = try CertificateAuthority(directory: caDir)
        captures.loadCA = { ca }
        captures.resolveADB = { URL(fileURLWithPath: "/fake/adb") }
        let installs = InstallLog()
        captures.caInstall = NetworkCAInstall(
            androidRooted: { _, serial, _ in installs.add("rooted \(serial)"); return .failed("boom") },
            androidPush: { _, serial, _ in installs.add("push \(serial)"); return true },
            simulatorInstall: { udid, _ in installs.add("sim \(udid)"); return .success(()) },
            simulatorReboot: { udid in installs.add("reboot \(udid)"); return .success(()) })

        let simulator = try await run("net install-ca sim-1")
        XCTAssertEqual(simulator.status, 0, simulator.printed.errText)
        XCTAssertEqual(simulator.printed.outText, "outcome    rebootAdvised  message\ninstalled  true")

        let android = try await run("net install-ca emu-1 --json")
        XCTAssertEqual(android.status, 1, "a failed install exits with status 1")
        let object = try XCTUnwrap(try json(android.printed) as? [String: Any])
        XCTAssertEqual(object["outcome"] as? String, "failed")
        XCTAssertEqual(object["message"] as? String, "boom")

        let unknown = try await run("net install-ca nothing")
        XCTAssertEqual(unknown.status, 1)
        XCTAssertEqual(unknown.printed.errText, "jaca: No network capture nothing.")
        XCTAssertEqual(installs.entries, ["sim sim-1", "rooted emu-1"])
    }

    // MARK: - The binary

    /// `jacad` run through a symlink named `jaca` is the command line, and talks to the daemon in
    /// `JACA_DAEMON_DIR`.
    func test_binary_invokedAsJaca() async throws {
        guard let jacad = DaemonLauncher.bundledExecutable, FileManager.default.isExecutableFile(atPath: jacad.path) else {
            throw XCTSkip("needs the jacad binary next to the test host")
        }
        try await openCaptures()
        let link = dir.appendingPathComponent("jaca")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: jacad)

        func jaca(_ arguments: String...) async throws -> (status: Int32, out: String, err: String) {
            let process = Process()
            process.executableURL = link
            process.arguments = arguments + ["--no-spawn"]
            var environment = ProcessInfo.processInfo.environment
            environment["JACA_DAEMON_DIR"] = daemon.paths.directory.path
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            // The daemon answers on this actor: wait for the process without blocking it.
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
            return (status,
                    String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }

        let listed = try await jaca("net", "requests", "--failed", "--json")
        XCTAssertEqual(listed.status, 0, listed.err)
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(listed.out.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)

        let shown = try await jaca("net", "show", "3fa2b")
        XCTAssertEqual(shown.status, 0, shown.err)
        XCTAssertTrue(shown.out.contains("responseBody:\n{\"error\":\"boom\"}"), shown.out)
        XCTAssertFalse(shown.out.contains("secret-token"))

        let added = try await jaca("overrides", "add", "--from", "3fa2b")
        XCTAssertEqual(added.status, 0, added.err)
        XCTAssertEqual(overrides.state.rules.map(\.name), ["POST orders"])

        let usage = try await jaca("net", "bogus")
        XCTAssertEqual(usage.status, 2)
        XCTAssertTrue(usage.err.hasPrefix("usage: jaca net list\n"), usage.err)
        XCTAssertEqual(usage.out, "")

        // The client commands `jacad` has work under this name too.
        let status = try await jaca("status")
        XCTAssertEqual(status.status, 0, status.err)
        XCTAssertTrue(status.out.contains("\"protocolVersion\""), status.out)
    }
}

/// The CA installs a test asked for, in order.
private final class InstallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ entry: String) { lock.withLock { list.append(entry) } }
    var entries: [String] { lock.withLock { list } }
}
