import XCTest
@testable import Jaca

/// The pure parts of `jaca`'s output: picking by prefix or name, redaction, tables, searches.
final class CLIOutputTests: XCTestCase {
    private struct Item: Equatable { var id: String; var name: String }

    private func resolve(_ input: String, _ items: [Item]) -> CLIMatch<Item> {
        CLIResolver.resolve(input, in: items, id: \.id, names: { [$0.name] })
    }

    private func one(_ match: CLIMatch<Item>) -> Item? {
        if case .one(let item) = match { return item }
        return nil
    }

    private func many(_ match: CLIMatch<Item>) -> [Item]? {
        if case .many(let items) = match { return items }
        return nil
    }

    private func isNone(_ match: CLIMatch<Item>) -> Bool {
        if case .none = match { return true }
        return false
    }

    // MARK: - Picking

    private let items = [
        Item(id: "3FA2B1C0-0000-4000-8000-000000000001", name: "Pixel 7"),
        Item(id: "3FA2FFFF-0000-4000-8000-000000000002", name: "iPhone 16"),
        Item(id: "9C000000-0000-4000-8000-000000000003", name: "pixel 7"),
    ]

    func test_resolve_byWholeIdPrefixOrName() {
        XCTAssertEqual(one(resolve("3fa2b1c0-0000-4000-8000-000000000001", items)), items[0], "a whole id, any case")
        XCTAssertEqual(one(resolve("3fa2b", items)), items[0], "a unique prefix")
        XCTAssertEqual(one(resolve("9", items)), items[2])
        XCTAssertEqual(one(resolve("iphone 16", items)), items[1], "a name, any case")
        XCTAssertEqual(one(resolve("  9c  ", items)), items[2], "surrounding spaces are ignored")
    }

    func test_resolve_ambiguousListsEveryFit() {
        XCTAssertEqual(many(resolve("3fa2", items)), [items[0], items[1]], "two ids share the prefix")
        XCTAssertEqual(many(resolve("Pixel 7", items)), [items[0], items[2]], "two sessions share the name")
    }

    func test_resolve_nothingFits() {
        XCTAssertTrue(isNone(resolve("zz", items)))
        XCTAssertTrue(isNone(resolve("ixel", items)), "a name must match whole, not in part")
        XCTAssertTrue(isNone(resolve("x", [])))
    }

    func test_resolve_emptyInputPicksTheOnlyCandidate() {
        XCTAssertEqual(one(resolve("", [items[1]])), items[1])
        XCTAssertEqual(many(resolve("", items)), items)
        XCTAssertTrue(isNone(resolve("", [])))
    }

    func test_resolve_emptyNamesNeverMatch() {
        let unnamed = [Item(id: "AA", name: ""), Item(id: "BB", name: "")]
        XCTAssertTrue(isNone(resolve("cc", unnamed)))
        XCTAssertEqual(one(resolve("a", unnamed)), unnamed[0])
    }

    /// A whole id is that item even when it is also the start of another id.
    func test_resolve_wholeIdBeatsALongerIdItStarts() {
        let nested = [Item(id: "AB", name: ""), Item(id: "ABC", name: "")]
        XCTAssertEqual(one(resolve("ab", nested)), nested[0])
        XCTAssertEqual(many(resolve("a", nested)), nested)
    }

    // MARK: - Redaction

    private let headers = [
        HeaderPair(name: "Accept", value: "*/*"),
        HeaderPair(name: "authorization", value: "Bearer abc.def"),
        HeaderPair(name: "Cookie", value: "sid=1"),
        HeaderPair(name: "SET-COOKIE", value: "sid=2; HttpOnly"),
        HeaderPair(name: "Proxy-Authorization", value: "Basic eA=="),
        HeaderPair(name: "X-Authorization-Hint", value: "kept"),
    ]

    func test_redaction_removesCredentialValuesOnly() {
        let redacted = CLIRedaction.headers(headers, raw: false)
        XCTAssertEqual(redacted.map(\.name), headers.map(\.name), "every header is still listed")
        XCTAssertEqual(redacted.map(\.redacted), [false, true, true, true, true, false])
        XCTAssertEqual(redacted.filter { !$0.redacted }.map(\.value), ["*/*", "kept"])
        for header in redacted where header.redacted {
            XCTAssertEqual(header.value, CLIRedaction.placeholder)
        }
        let text = String(decoding: try! JSONEncoder.daemon.encode(redacted), as: UTF8.self)
        for secret in ["abc.def", "sid=1", "sid=2", "eA=="] {
            XCTAssertFalse(text.contains(secret), secret)
        }
    }

    func test_redaction_rawKeepsEverything() {
        let raw = CLIRedaction.headers(headers, raw: true)
        XCTAssertEqual(raw.map(\.value), headers.map(\.value))
        XCTAssertFalse(raw.contains { $0.redacted })
    }

    // MARK: - Request detail

    private func transaction() -> NetworkTransaction {
        var t = NetworkTransaction(id: UUID(uuidString: "3FA2B1C0-0000-4000-8000-000000000001")!, method: "POST",
                                   url: "https://api.example.com/login", host: "api.example.com", scheme: "https",
                                   requestHeaders: [HeaderPair(name: "Authorization", value: "Bearer secret"),
                                                    HeaderPair(name: "X-Jaca-Flow", value: "internal")],
                                   requestBody: Data("{\"user\":\"a\"}".utf8),
                                   startedAt: Date(timeIntervalSince1970: 1_790_000_000))
        t.statusCode = 500
        t.responseHeaders = [HeaderPair(name: "Content-Type", value: "application/json"), HeaderPair(name: "Set-Cookie", value: "sid=9")]
        t.responseBody = Data("{\"error\":\"boom\"}".utf8)
        t.finishedAt = t.startedAt.addingTimeInterval(0.1234)
        return t
    }

    func test_request_textListsFieldsHeadersAndBodies() {
        let session = UUID(uuidString: "9C000000-0000-4000-8000-000000000003")!
        let text = CLIRequest(transaction(), session: session, raw: false).text
        XCTAssertEqual(text, """
        id: 3FA2B1C0-0000-4000-8000-000000000001
        session: 9C000000-0000-4000-8000-000000000003
        method: POST
        url: https://api.example.com/login
        statusCode: 500
        startedAt: \(DaemonDates.format(Date(timeIntervalSince1970: 1_790_000_000)))
        durationMs: 123

        requestHeaders:
        Authorization: \(CLIRedaction.placeholder)

        requestBody:
        {"user":"a"}

        responseHeaders:
        Content-Type: application/json
        Set-Cookie: \(CLIRedaction.placeholder)

        responseBody:
        {"error":"boom"}
        """)
        XCTAssertFalse(text.contains("X-Jaca"), "Jaca's own markers are not the app's headers")
        XCTAssertTrue(CLIRequest(transaction(), session: session, raw: true).text.contains("Authorization: Bearer secret"))
    }

    func test_request_jsonKeepsFieldNamesAndRedacts() throws {
        let detail = CLIRequest(transaction(), session: UUID(), raw: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.daemon.encode(detail)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "id", "session", "method", "url", "statusCode", "startedAt", "durationMs",
            "requestHeaders", "requestBody", "responseHeaders", "responseBody",
        ])
        let requestHeaders = try XCTUnwrap(object["requestHeaders"] as? [[String: Any]])
        XCTAssertEqual(requestHeaders.first?["name"] as? String, "Authorization")
        XCTAssertEqual(requestHeaders.first?["redacted"] as? Bool, true)
        XCTAssertEqual(object["responseBody"] as? String, "{\"error\":\"boom\"}")
    }

    func test_request_bodyThatIsNotTextIsBase64() {
        var t = transaction()
        t.responseBody = Data([0xFF, 0xFE, 0x00])
        t.requestBody = nil
        let detail = CLIRequest(t, session: UUID(), raw: false)
        XCTAssertNil(detail.responseBody)
        XCTAssertEqual(detail.responseBodyBase64, "//4A")
        XCTAssertNil(detail.requestBody)
        XCTAssertNil(detail.requestBodyBase64)
        XCTAssertTrue(detail.text.contains("responseBodyBase64:\n//4A"))
        XCTAssertFalse(detail.text.contains("requestBody"))
    }

    // MARK: - Tables

    func test_table_padsColumnsAndKeepsRowsOnOneLine() {
        let text = CLITable.render(["id", "name", "note"], [["1", "alpha", "x"], ["22", "b", "two\nlines\there"]])
        XCTAssertEqual(text, """
        id  name   note
        1   alpha  x
        22  b      two lines here
        """)
        XCTAssertEqual(CLITable.render(["id", "name"], []), "id  name", "no rows: the header alone")
    }

    func test_rows_matchTheirHeaders() {
        let device = Device(id: "emu-1", platform: .android, model: "Pixel", state: .connected)
        XCTAssertEqual(device.cells.count, Device.header.count)
        XCTAssertEqual(device.cells, ["emu-1", "android", "connected", "Pixel"])

        var rule = OverrideRule(name: "Stub")
        rule.matcher = OverrideMatcher(pattern: "https://a/*", kind: .glob, methods: ["POST", "GET"])
        rule.action = .respond(OverrideResponseSpec(statusCode: 418, headers: [], body: .inline("{}")))
        let row = CLIRule(rule, hitCount: 3)
        XCTAssertEqual(row.cells.count, CLIRule.header.count)
        XCTAssertEqual(row.cells, [String(rule.id.uuidString.prefix(8)), "true", "3", "respond", "418", "GET,POST", "", "https://a/*", "Stub"])

        let txn = transaction()
        let request = NetworkArea.Row(txn, session: UUID())
        XCTAssertEqual(request.cells.count, NetworkArea.Row.header.count)
        XCTAssertEqual(request.durationMs, 123)
        XCTAssertEqual(Array(request.cells[2...6]), ["POST", "500", "123", "0", "https://api.example.com/login"])
    }

    // MARK: - Network mode and CA install

    func test_networkMode_tableAndJSON() throws {
        let mode = CLINetworkMode(NetworkModeController.State(mode: "mitm", switching: false))
        XCTAssertEqual(CLITable.render(CLINetworkMode.header, [mode.cells]), "mode\nmitm")
        let text = String(decoding: try JSONEncoder.daemon.encode(mode), as: UTF8.self)
        XCTAssertEqual(text, #"{"mode":"mitm"}"#)
    }

    func test_installCAResult_tableAndJSON() throws {
        let simulator = NetworkArea.InstallCAResult(outcome: .installed, rebootAdvised: true)
        let failed = NetworkArea.InstallCAResult(outcome: .failed, message: "not booted")
        XCTAssertEqual(simulator.cells.count, NetworkArea.InstallCAResult.header.count)
        XCTAssertEqual(CLITable.render(NetworkArea.InstallCAResult.header,
                                       [simulator.cells, failed.cells, NetworkArea.InstallCAResult(outcome: .needsUser).cells]), """
        outcome    rebootAdvised  message
        installed  true
        failed                    not booted
        needsUser
        """)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.daemon.encode(simulator)) as? [String: Any])
        XCTAssertEqual(object["outcome"] as? String, "installed")
        XCTAssertEqual(object["rebootAdvised"] as? Bool, true)
    }

    // MARK: - Searches

    private func line(_ message: String, level: LogLevel = .info, tag: String = "App", at seconds: TimeInterval = 0, seq: UInt64 = 0) -> LogLine {
        LogLine(seq: seq, timestamp: Date(timeIntervalSince1970: seconds), level: level, tag: tag, pid: 1, tid: 0,
                message: message, raw: message)
    }

    func test_logSearch_levelSinceAndPattern() {
        XCTAssertTrue(LogSearch().matches(line("anything", level: .verbose)))
        let errors = LogSearch(minLevel: .error)
        XCTAssertTrue(errors.matches(line("x", level: .fatal)))
        XCTAssertFalse(errors.matches(line("x", level: .warn)))
        XCTAssertTrue(errors.matches(.marker("crashed", critical: true)), "a crash marker passes a level filter")
        XCTAssertFalse(errors.matches(.marker("reconnected")))

        let recent = LogSearch(since: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(recent.matches(line("x", at: 100)))
        XCTAssertFalse(recent.matches(line("x", at: 99)))

        let timeouts = LogSearch(pattern: "time.?out")
        XCTAssertTrue(timeouts.matches(line("Request TIMEOUT after 30s")))
        XCTAssertTrue(timeouts.matches(line("x", tag: "TimeOutWatcher")), "the tag is searched too")
        XCTAssertFalse(timeouts.matches(line("timing")))
    }

    func test_logSearch_anInvalidPatternIsMatchedAsText() {
        let search = LogSearch(pattern: "[oops")
        XCTAssertTrue(search.matches(line("value [OOPS here")))
        XCTAssertFalse(search.matches(line("fine")))
    }

    func test_logSearch_tailKeepsTheNewestMatchesInOrder() {
        let lines = (1...6).map { line($0.isMultiple(of: 2) ? "even \($0)" : "odd \($0)", seq: UInt64($0)) }
        XCTAssertEqual(LogSearch(pattern: "even").tail(lines, limit: 2).map(\.seq), [4, 6])
        XCTAssertEqual(LogSearch().tail(lines, limit: 100).count, 6)
        XCTAssertEqual(LogSearch().tail(lines, limit: 0), [])
    }

    func test_networkSearch_everySetFieldMustMatch() {
        var ok = transaction()                      // POST api.example.com 500
        ok.statusCode = 503
        var notFound = transaction(); notFound.statusCode = 404
        var fine = transaction(); fine.statusCode = 200
        var broken = transaction(); broken.statusCode = nil; broken.error = "timed out"
        var pending = transaction(); pending.statusCode = nil

        XCTAssertTrue(NetworkSearch().matches(pending), "no filter matches everything")
        XCTAssertTrue(NetworkSearch(host: "EXAMPLE").matches(ok))
        XCTAssertFalse(NetworkSearch(host: "other.com").matches(ok))
        XCTAssertTrue(NetworkSearch(method: "post").matches(ok))
        XCTAssertFalse(NetworkSearch(method: "GET").matches(ok))

        let fiveHundreds = NetworkSearch(status: [NetworkStatusRange(min: 500, max: 599)])
        XCTAssertTrue(fiveHundreds.matches(ok))
        XCTAssertFalse(fiveHundreds.matches(notFound))
        XCTAssertFalse(fiveHundreds.matches(pending), "no response yet is no status")

        let failed = NetworkSearch(failed: true)
        XCTAssertTrue(failed.matches(ok) && failed.matches(notFound) && failed.matches(broken))
        XCTAssertFalse(failed.matches(fine) || failed.matches(pending))

        XCTAssertTrue(NetworkSearch(idPrefix: "3fa2").matches(ok))
        XCTAssertFalse(NetworkSearch(idPrefix: "fa2").matches(ok), "a prefix, not a substring")
        XCTAssertFalse(NetworkSearch(host: "example", status: [NetworkStatusRange(min: 404, max: 404)]).matches(ok))
    }

    /// A range that arrives without a bound leaves that side open instead of failing the request.
    func test_statusRange_decodesTolerantly() throws {
        let open = try JSONDecoder.daemon.decode(NetworkStatusRange.self, from: Data(#"{"min":500}"#.utf8))
        XCTAssertTrue(open.contains(599) && !open.contains(499))
        let any = try JSONDecoder.daemon.decode(NetworkStatusRange.self, from: Data(#"{"max":"x","later":1}"#.utf8))
        XCTAssertTrue(any.contains(200))
    }
}
