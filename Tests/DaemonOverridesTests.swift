import XCTest
@testable import Jaca

/// Response overrides with the runtime in the daemon. Every test points the rule library at a
/// temporary directory (`JACA_OVERRIDES_DIR`), so the user's rules are never touched.
@MainActor
final class DaemonOverridesTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ov-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("JACA_OVERRIDES_DIR", dir.path, 1)
    }

    override func tearDown() async throws {
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

    private func rule(_ pattern: String) -> OverrideRule {
        var r = OverrideRule()
        r.name = "Stub"
        r.matcher = OverrideMatcher(pattern: pattern, kind: .glob, methods: ["GET"])
        r.action = .respond(OverrideResponseSpec(statusCode: 418, headers: [], body: .inline("{}")))
        return r
    }

    // MARK: - Wire formats

    func test_armingState_roundTripsEveryCase() throws {
        let cases: [InterceptArmingState] = [
            .idle, .waitingForAgent, .agentTooOld, .waitingForApp(appID: "a"), .detached(appID: "b"),
            .active(port: 4321, hosts: ["api.example.com", "cdn.example.com"]), .failed("boom"),
        ]
        for state in cases {
            let back = try JSONDecoder.daemon.decode(InterceptArmingState.self, from: JSONEncoder.daemon.encode(state))
            XCTAssertEqual(back, state)
        }
        XCTAssertEqual(try JSONDecoder.daemon.decode(InterceptArmingState.self, from: Data(#"{"state":"later"}"#.utf8)), .idle)
    }

    func test_overridesState_roundTrips() throws {
        var state = OverridesState()
        state.rules = [rule("https://api.example.com/*")]
        state.hitCounts = [state.rules[0].id.uuidString: 3]
        state.armings = [.init(target: InterceptTarget(deviceID: "sim", package: "com.x"), state: .waitingForAgent)]
        state.lastActivity = "12:00 · applied Stub"
        let back = try JSONDecoder.daemon.decode(OverridesState.self, from: JSONEncoder.daemon.encode(state))
        XCTAssertEqual(back.rules.map(\.id), state.rules.map(\.id))
        XCTAssertEqual(back.hitCounts, state.hitCounts)
        XCTAssertEqual(back.armings, state.armings)
        XCTAssertEqual(back.lastActivity, state.lastActivity)
    }

    // MARK: - Two engines, one file

    /// The app's engine and the daemon's both write `rules.json` over time; each re-reads it before
    /// mutating, so neither saves a stale list over the other's edit.
    func test_engines_neverOverwriteEachOthersEdits() throws {
        let app = OverridesEngine()
        let daemon = OverridesEngine()           // loaded before the app's edit
        let first = rule("https://a.example.com/*")
        app.save(first)
        // File timestamps have one-second resolution on some volumes: make the change visible.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: OverrideRuleStore.rulesURL.path)
        let second = rule("https://b.example.com/*")
        daemon.save(second)
        let onDisk = OverrideRuleStore.load().map(\.id)
        XCTAssertEqual(Set(onDisk), [first.id, second.id])
    }

    /// A hand edit that breaks `rules.json` must not empty the library on the next mutation.
    func test_brokenRulesFile_keepsTheLibraryInMemory() throws {
        let engine = OverridesEngine()
        let kept = rule("https://a.example.com/*")
        engine.save(kept)
        try Data("[{\"broken\": ".utf8).write(to: OverrideRuleStore.rulesURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: OverrideRuleStore.rulesURL.path)
        let added = rule("https://b.example.com/*")
        engine.save(added)
        XCTAssertEqual(Set(OverrideRuleStore.load().map(\.id)), [kept.id, added.id])
    }

    /// Starting on a broken `rules.json` (nothing in memory yet): edits don't save over it.
    func test_brokenRulesFileAtLaunch_isNotOverwritten() throws {
        try FileManager.default.createDirectory(at: OverrideRuleStore.directory, withIntermediateDirectories: true)
        let broken = Data("[{\"broken\": ".utf8)
        try broken.write(to: OverrideRuleStore.rulesURL)
        let engine = OverridesEngine()
        engine.save(rule("https://a.example.com/*"))
        XCTAssertEqual(try Data(contentsOf: OverrideRuleStore.rulesURL), broken)
    }

    /// The master switch lives in defaults: a write by the other process is picked up.
    func test_masterSwitch_isReReadBeforeAMutation() {
        let engine = OverridesEngine()
        let before = FeatureFlags.overridesMasterEnabled
        defer { FeatureFlags.overridesMasterEnabled = before }
        FeatureFlags.overridesMasterEnabled = !engine.state.masterEnabled
        engine.save(rule("https://c.example.com/*"))
        XCTAssertEqual(engine.state.masterEnabled, FeatureFlags.overridesMasterEnabled)
    }

    // MARK: - GC grace

    func test_gc_keepsAFreshUnsavedBlob() throws {
        let ref = OverrideRuleStore.makeBodyRef(Data(repeating: 65, count: 10_000))
        guard case .blob(let file) = ref else { return XCTFail("a 10 KB body spills to a blob") }
        OverrideRuleStore.collectGarbage(keeping: [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: OverrideRuleStore.bodiesDirectory.appendingPathComponent(file).path),
                      "a blob written for a rule still in the editor survives another save")
        OverrideRuleStore.collectGarbage(keeping: [], now: Date().addingTimeInterval(2 * 24 * 60 * 60))
        XCTAssertFalse(FileManager.default.fileExists(atPath: OverrideRuleStore.bodiesDirectory.appendingPathComponent(file).path),
                       "an old unreferenced blob is still collected")
    }

    // MARK: - Daemon + the app model

    func test_modelMirrorsTheDaemonAndSendsEdits() async throws {
        let daemon = try TestDaemon()
        let engine = OverridesArea.install(on: daemon.server)
        let connector = DaemonConnector(paths: daemon.paths, executable: nil, enabledAreas: [.network])
        let model = OverridesModel(daemon: connector, inDaemon: true)
        XCTAssertTrue(model.usesDaemon)
        XCTAssertNil(model.localServices, "the runtime is in the daemon, not here")

        let r = rule("https://api.example.com/users/*")
        model.save(r)
        try await waitUntil { engine.state.rules.contains { $0.id == r.id } }
        try await waitUntil { model.rules.contains { $0.id == r.id } }
        // Match previews run on the mirrored rules, compiled in the app.
        XCTAssertEqual(model.matchingRule(forURL: "https://api.example.com/users/42", method: "GET")?.id, r.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rules.json").path),
                      "the daemon wrote the library")

        model.setEnabled(false, for: r.id)
        try await waitUntil { model.rules.first { $0.id == r.id }?.enabled == false }
        XCTAssertNil(model.matchingRule(forURL: "https://api.example.com/users/42", method: "GET"))

        model.duplicate(r.id)
        try await waitUntil { model.rules.count == 2 }
        let copy = try XCTUnwrap(model.rules.last)
        model.move(copy.id, by: -1)
        try await waitUntil { model.rules.first?.id == copy.id }

        model.remove(r.id)
        model.remove(copy.id)
        try await waitUntil { model.rules.isEmpty && engine.state.rules.isEmpty }
    }

    func test_arming_reportedInTheDaemonReachesTheApp() async throws {
        let daemon = try TestDaemon()
        let engine = OverridesArea.install(on: daemon.server)
        let connector = DaemonConnector(paths: daemon.paths, executable: nil, enabledAreas: [.network])
        let model = OverridesModel(daemon: connector, inDaemon: true)
        let target = InterceptTarget(deviceID: "sim-1", package: "com.example.app")

        // A capture source in the daemon reports through the engine's services.
        engine.services().reportArming(target: target, coordinator: nil, state: .waitingForAgent)
        try await waitUntil { model.arming(for: target) == .waitingForAgent }
    }

    // MARK: - One switch

    func test_theNetworkArea_decidesWhereNetworkRuns() {
        let connector = DaemonConnector(paths: DaemonPaths(directory: URL(fileURLWithPath: "/nonexistent")),
                                        executable: nil, enabledAreas: [.network])
        XCTAssertTrue(connector.networkRunsInDaemon(), "the inspection mode no longer keeps network in the app")
        let off = DaemonConnector(paths: DaemonPaths(directory: URL(fileURLWithPath: "/nonexistent")),
                                  executable: nil, enabledAreas: [])
        XCTAssertFalse(off.networkRunsInDaemon())
    }

    /// Moving the runtime into the app and back: in the app the local engine owns the library;
    /// back in the daemon, the daemon re-reads what the app wrote.
    func test_runtimeMovesAndTheDaemonRereadsTheLibrary() async throws {
        let daemon = try TestDaemon()
        let engine = OverridesArea.install(on: daemon.server)
        let connector = DaemonConnector(paths: daemon.paths, executable: nil, enabledAreas: [.network])
        let model = OverridesModel(daemon: connector, inDaemon: true)
        XCTAssertNil(model.localServices)

        model.setRuntime(inDaemon: false)          // HTTPS decryption turned on
        XCTAssertNotNil(model.localServices, "the app runs the overrides now")
        let r = rule("https://api.example.com/*")
        model.save(r)
        XCTAssertTrue(model.rules.contains { $0.id == r.id }, "saved in-process, synchronously")
        XCTAssertFalse(engine.state.rules.contains { $0.id == r.id }, "the daemon isn't told")

        model.setRuntime(inDaemon: true)           // and off again
        try await waitUntil { engine.state.rules.contains { $0.id == r.id } }
        XCTAssertNil(model.localServices)
        try await waitUntil { model.rules.contains { $0.id == r.id } }
    }
}
