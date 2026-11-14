import XCTest
@testable import Jaca

/// The schemas `api.describe` carries. They are written by hand, so each is checked against a
/// value of the type it describes: a key the type encodes and the schema doesn't list fails here.
@MainActor
final class DaemonSchemaTests: XCTestCase {
    // MARK: - Checking a value against a schema

    /// Paths in `value` that `schema` doesn't describe: unlisted keys, missing required ones, and
    /// containers of the wrong kind.
    private func mismatches(_ value: Any, _ schema: DaemonSchema, at path: String = "$") -> [String] {
        if let variants = schema.oneOf {
            let perVariant = variants.map { mismatches(value, $0, at: path) }
            return perVariant.contains { $0.isEmpty } ? [] : ["\(path): no variant fits (\(perVariant.first ?? []))"]
        }
        if let object = value as? [String: Any] {
            guard schema.type == "object" || schema.type == nil else { return ["\(path): object where \(schema.summary) is described"] }
            var found = (schema.required ?? []).filter { object[$0] == nil }.map { "\(path).\($0): required, absent" }
            for (key, child) in object {
                if let property = schema.properties?[key] {
                    found += mismatches(child, property, at: "\(path).\(key)")
                } else if let additional = schema.additionalProperties {
                    found += mismatches(child, additional, at: "\(path).\(key)")
                } else {
                    found.append("\(path).\(key): not in the schema")
                }
            }
            return found
        }
        if let array = value as? [Any] {
            guard schema.type == "array", let items = schema.items else { return ["\(path): array where \(schema.summary) is described"] }
            return array.enumerated().flatMap { mismatches($0.element, items, at: "\(path)[\($0.offset)]") }
        }
        switch schema.type {
        case "object", "array": return ["\(path): scalar where \(schema.summary) is described"]
        case "string":
            guard let text = value as? String else { return ["\(path): not a string"] }
            if let values = schema.values, !values.contains(text) { return ["\(path): \(text) is not one of \(values)"] }
            return []
        case "null": return value is NSNull ? [] : ["\(path): not null"]
        default: return []
        }
    }

    private func assertDescribed<T: Encodable>(_ value: T, by schema: DaemonSchema, _ what: String,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.daemon.encode(value), options: [.fragmentsAllowed])
        XCTAssertEqual(mismatches(json, schema), [], what, file: file, line: line)
    }

    // MARK: - Samples

    private let device = Device(id: "emu-1", platform: .iosSimulator, model: "Sim", state: .booted)

    private var armingStates: [InterceptArmingState] {
        [.idle, .waitingForAgent, .agentTooOld, .waitingForApp(appID: "a"), .detached(appID: "b"),
         .active(port: 4321, hosts: ["api.example.com"]), .failed("boom")]
    }

    private static let groupID = UUID()

    private var rules: [OverrideRule] {
        let bodies: [OverrideBodyRef] = [.none, .inline("{}"), .blob(filename: "a.bin"), .file(path: "/tmp/a.json", watch: true)]
        var all = bodies.map { body -> OverrideRule in
            OverrideRule(name: "Respond", matcher: OverrideMatcher(pattern: "https://a/*", kind: .regex, methods: ["GET"]),
                         scope: OverrideScope(deviceIDs: ["emu-1"], appIDs: ["com.x"]),
                         action: .respond(OverrideResponseSpec(statusCode: 418, headers: [HeaderPair(name: "A", value: "b")], body: body)),
                         delayMillis: 20, routedHosts: ["a"], groupID: Self.groupID)
        }
        all.append(OverrideRule(action: .editResponse(ResponseEdit(statusCode: 500, headerMode: .replace,
                                                                  headers: [HeaderPair(name: "A", value: "b")],
                                                                  removeHeaders: ["ETag"], body: .inline("x")))))
        all.append(OverrideRule(action: .editResponse(ResponseEdit())))
        all.append(OverrideRule(action: .mapRemote(url: "https://staging.example.com")))
        return all
    }

    private var transaction: NetworkTransaction {
        var t = NetworkTransaction(method: "GET", url: "https://api.example.com/1", host: "api.example.com", scheme: "https",
                                   requestHeaders: [HeaderPair(name: "Accept", value: "*/*")], requestBody: Data("q".utf8))
        t.statusCode = 200
        t.responseHeaders = [HeaderPair(name: "Content-Type", value: "text/plain")]
        t.responseBody = Data("ok".utf8)
        t.responseContentType = "text/plain"
        t.responseReceivedAt = t.startedAt.addingTimeInterval(0.05)
        t.finishedAt = t.startedAt.addingTimeInterval(0.1)
        t.error = "late"
        t.callStack = ["a.b"]
        t.overriddenByRuleID = UUID()
        t.httpStack = "okhttp3"
        t.bodiesEvicted = true
        return t
    }

    // MARK: - Drift

    func test_everyEncodedKeyIsInItsSchema() throws {
        try assertDescribed(device, by: .device, "Device")

        var line = LogLine(seq: 8, timestamp: Date(), level: .error, tag: "T", pid: 7, tid: 9, message: "pretty", raw: "raw")
        line.processName = "App"
        line.isMarker = true
        line.markerCritical = true
        line.isConsoleOutput = true
        line.bodyCompact = "{}"
        try assertDescribed(line, by: .logLine, "LogLine")

        let logState = LogStreamState(isRunning: true, isConnecting: true, statusMessage: "m", package: "com.x", pids: [1])
        try assertDescribed(logState, by: .logStreamState, "LogStreamState")
        try assertDescribed(LogsArea.SessionInfo(id: UUID(), device: device, displayName: "n", state: logState, lastSeq: 8, existed: false),
                            by: .logSession, "LogsArea.SessionInfo")

        for arming in armingStates {
            try assertDescribed(arming, by: .interceptArmingState, "InterceptArmingState \(arming)")
            var state = NetworkCaptureState()
            state.statusMessage = "m"
            state.selectedSourceID = "agent"
            state.targetPackage = "com.x"
            state.attachState = arming
            state.offeredSourceIDs = ["mitm", "browser"]
            try assertDescribed(state, by: .networkCaptureState, "NetworkCaptureState")
            try assertDescribed(NetworkArea.Session(id: UUID(), name: "Sim", device: device, state: state, transactionCount: 2),
                                by: .networkSession, "NetworkArea.Session")
        }

        for mode in NetworkInspectionMode.allCases {
            for switching in [false, true] {
                try assertDescribed(NetworkModeController.State(mode: mode.wireName, switching: switching),
                                    by: .networkMode, "network.mode \(mode.wireName)")
            }
        }
        try assertDescribed(NetworkArea.SetModeParams(mode: "mitm"),
                            by: .object(["mode": .enumeration(["agent", "mitm"])]), "network.setMode params")
        let installResults = [
            NetworkArea.InstallCAResult(outcome: .installed),
            NetworkArea.InstallCAResult(outcome: .installed, rebootAdvised: true),
            NetworkArea.InstallCAResult(outcome: .needsUser),
            NetworkArea.InstallCAResult(outcome: .failed, message: "m"),
        ]
        for result in installResults {
            try assertDescribed(result, by: .networkInstallCAResult, "network.installCA \(result.outcome)")
        }

        try assertDescribed(transaction, by: .networkTransaction, "NetworkTransaction")
        try assertDescribed(NetworkArea.Row(transaction, session: UUID()), by: .networkRow, "NetworkArea.Row")
        try assertDescribed(NetworkStatusRange(min: 400, max: 499), by: .networkStatusRange, "NetworkStatusRange")

        for rule in rules {
            try assertDescribed(rule, by: .overrideRule, "OverrideRule \(rule.action)")
        }
        var state = OverridesState()
        state.rules = rules
        state.hitCounts = [rules[0].id.uuidString: 3]
        state.lastHitAt = [rules[0].id.uuidString: Date()]
        state.armings = armingStates.map { .init(target: InterceptTarget(deviceID: "sim", package: "com.x"), state: $0) }
        state.lastActivity = "12:00 · applied Stub"
        state.reclaimedTunnelCount = 1
        state.groups = [OverrideGroup(id: Self.groupID, name: "Deals", enabled: false)]
        try assertDescribed(state.groups[0], by: .overrideGroup, "OverrideGroup")
        try assertDescribed(state, by: .overridesState, "OverridesState")
    }

    /// The check itself: it must notice a key the schema lacks, and a missing required one.
    func test_theDriftCheckCatchesAnUnlistedKey() throws {
        struct Wider: Encodable { var id = "emu-1"; var platform = "android"; var battery = 80 }
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.daemon.encode(Wider()))
        XCTAssertEqual(mismatches(json, .device), ["$.battery: not in the schema"])
        XCTAssertEqual(mismatches(["platform": "tv"], .device).sorted(),
                       ["$.id: required, absent", "$.platform: tv is not one of [\"android\", \"iosSimulator\", \"iosDevice\", \"mac\"]"])
        XCTAssertFalse(mismatches(["kind": "inline"], .overrideBodyRef).isEmpty, "inline needs its text")
    }

    // MARK: - Coding

    func test_schema_encodesAsJSONSchemaAndRoundTrips() throws {
        let schema = DaemonSchema.object(["id": .uuid], optional: [
            "kind": .enumeration(["glob", "regex"]), "tags": .array(.string), "counts": .map(.integer),
            "body": .nullable(.overrideBodyRef), "s": DaemonSchema.integer.titled("seq"),
        ])
        let data = try JSONEncoder.daemon.encode(schema)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "object")
        XCTAssertEqual(object["required"] as? [String], ["id"])
        let properties = try XCTUnwrap(object["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["id"]?["format"] as? String, "uuid")
        XCTAssertEqual(properties["kind"]?["enum"] as? [String], ["glob", "regex"])
        XCTAssertEqual((properties["tags"]?["items"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((properties["counts"]?["additionalProperties"] as? [String: Any])?["type"] as? String, "integer")
        XCTAssertEqual(properties["s"]?["title"] as? String, "seq")
        XCTAssertEqual((properties["body"]?["oneOf"] as? [Any])?.count, 2)
        XCTAssertEqual(try JSONDecoder.daemon.decode(DaemonSchema.self, from: data), schema)
    }

    /// A schema from another build: wrong types and unknown keywords are dropped, not fatal.
    func test_schema_decodesTolerantly() throws {
        let json = #"{"type":7,"enum":"x","properties":{"a":{"type":"string","const":"v"}},"required":3,"items":[1],"$id":"later"}"#
        let schema = try JSONDecoder.daemon.decode(DaemonSchema.self, from: Data(json.utf8))
        XCTAssertNil(schema.type)
        XCTAssertNil(schema.values)
        XCTAssertNil(schema.required)
        XCTAssertNil(schema.items)
        XCTAssertEqual(schema.properties?["a"], .string)
    }

    /// `api.describe` from a daemon that predates the schemas still decodes.
    func test_methodInfo_oldSchemaDecodesWithoutSchemas() throws {
        let json = #"{"protocolVersion":1,"methods":[{"name":"ping","summary":"Liveness check."},{"name":"x"}],"topics":[]}"#
        let catalog = try JSONDecoder.daemon.decode(DaemonServer.Catalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.methods.map(\.name), ["ping", "x"])
        XCTAssertEqual(catalog.methods[0].summary, "Liveness check.")
        XCTAssertNil(catalog.methods[0].params)
        XCTAssertNil(catalog.methods[0].result)
        XCTAssertEqual(catalog.methods[1].summary, "")
    }

    // MARK: - Rendering

    func test_rendered_showsARulesShape() {
        let lines = DaemonSchema.overrideRule.rendered()
        XCTAssertTrue(lines.contains("id: uuid"), "\(lines)")
        XCTAssertTrue(lines.contains("enabled?: boolean"))
        XCTAssertTrue(lines.contains("divertHosts? (routedHosts): string[]"))
        XCTAssertTrue(lines.contains("matcher?: object"))
        XCTAssertTrue(lines.contains("  kind?: \"glob\" | \"regex\""))
        XCTAssertTrue(lines.contains("action?: oneOf"))
        XCTAssertTrue(lines.contains("    kind: \"editResponse\""))
        XCTAssertTrue(lines.contains("          kind: \"inline\""), "a body under an action variant: \(lines)")
        XCTAssertEqual(DaemonSchema.nullable(.bytes).summary, "byte | null")
        XCTAssertEqual(DaemonSchema.array(.networkRow).summary, "object[]")
        XCTAssertEqual(DaemonSchema.map(.date).summary, "{string: date-time}")
    }

    // MARK: - api.describe

    /// Every method of the areas `jaca` drives says what it takes and returns.
    func test_describe_carriesSchemasForTheCLIAreas() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("JACA_OVERRIDES_DIR", dir.path, 1)
        defer {
            unsetenv("JACA_OVERRIDES_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        let daemon = try TestDaemon()
        let captures = NetworkArea.Captures(bus: daemon.server.bus, bodyCache: nil)
        OverridesArea.install(on: daemon.server, captures: captures)
        NetworkArea.install(on: daemon.server, captures: captures)
        LogsArea.install(on: daemon.server, registry: LogsArea.Registry(bus: daemon.server.bus, history: nil))
        DevicesArea.install(on: daemon.server, engine: DevicesEngine(defaults: .standard) { _ in [] })

        let client = try await daemon.client()
        let catalog: DaemonServer.Catalog = try await client.call("api.describe")
        let described = catalog.methods.filter { method in
            ["devices.", "logs.", "network.", "overrides."].contains { method.name.hasPrefix($0) }
        }
        XCTAssertGreaterThan(described.count, 30)
        for method in described {
            XCTAssertNotNil(method.params, "\(method.name) params")
            XCTAssertNotNil(method.result, "\(method.name) result")
        }
        for name in CLIUsage.entries.flatMap(\.methods) {
            XCTAssertTrue(described.contains { $0.name == name }, "\(name) is behind a jaca command")
        }
        let mode = try XCTUnwrap(described.first { $0.name == "network.mode" })
        XCTAssertEqual(mode.result, .networkMode)
        let setMode = try XCTUnwrap(described.first { $0.name == "network.setMode" })
        XCTAssertEqual(setMode.params?.required, ["mode"])
        let installCA = try XCTUnwrap(described.first { $0.name == "network.installCA" })
        XCTAssertEqual(installCA.params?.required, ["id"])
        XCTAssertEqual(installCA.result, .networkInstallCAResult)
        XCTAssertNotNil(described.first { $0.name == "network.rebootSimulator" })
        XCTAssertTrue(catalog.topics.contains { $0.name == NetworkModeController.topic && $0.retained })

        let create = try XCTUnwrap(described.first { $0.name == "overrides.createFromTransaction" })
        XCTAssertEqual(create.params?.required, ["id", "transaction"])
        XCTAssertEqual(create.result?.oneOf?.first?.properties?["rule"], .overrideRule)
    }
}
