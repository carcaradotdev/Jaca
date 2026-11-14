import XCTest
@testable import Jaca

/// Phase 2 areas over the daemon socket, plus the wire formats they rely on.
final class DaemonAreasTests: XCTestCase {
    // MARK: - Wire formats

    func test_gradleDaemon_roundTripsWithoutViewState() throws {
        var d = GradleDaemon(pid: 42, version: "9.7.0", uptime: "2h", cpu: 1.5, memoryMB: 300, jdk: "21", maxHeap: "12g")
        d.removing = true
        let data = try JSONEncoder.daemon.encode(d)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("removing"))
        let back = try JSONDecoder.daemon.decode(GradleDaemon.self, from: data)
        XCTAssertEqual(back.pid, 42)
        XCTAssertEqual(back.jdk, "21")
        XCTAssertFalse(back.removing)
    }

    func test_gradleDaemon_missingFieldsDecodeToDefaults() throws {
        let back = try JSONDecoder.daemon.decode(GradleDaemon.self, from: Data(#"{"pid":7}"#.utf8))
        XCTAssertEqual(back.version, "?")
        XCTAssertEqual(back.memoryMB, 0)
        XCTAssertNil(back.maxHeap)
    }

    func test_derivedDataEntry_unknownKindReadsAsShared() throws {
        let json = #"{"path":"/x/Foo-abc","name":"Foo","sizeMB":5,"kind":"future"}"#
        let entry = try JSONDecoder.daemon.decode(DerivedDataEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.kind, .shared)
        XCTAssertEqual(entry.name, "Foo")
    }

    /// An old cache/daemon record that predates most checkout fields must still load.
    func test_projectCheckout_oldSchemaDecodesWithDefaults() throws {
        let json = #"[{"path":"/r","exists":true,"isGitRepo":true,"source":"claude","sessionCount":2,"checkouts":[{"path":"/r","isMain":true,"exists":true},{"bad":1}]}]"#
        let projects = CloudPersistence.decodeArray(Project.self, from: Data(json.utf8))
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].checkouts.count, 1, "the malformed checkout is skipped, the rest kept")
        XCTAssertEqual(projects[0].checkouts[0].sizeMB, 0)
        XCTAssertFalse(projects[0].checkouts[0].sizeComputed)
    }

    func test_projectsState_roundTripsOverTheDaemonCoders() throws {
        var state = ProjectsState()
        state.projects = [Project(path: "/r", exists: true, isGitRepo: false, source: .user,
                                  sessionCount: 0, lastActive: Date(timeIntervalSince1970: 1_700_000_000), checkouts: [])]
        state.scanGeneration = 3
        let back = try JSONDecoder.daemon.decode(ProjectsState.self, from: JSONEncoder.daemon.encode(state))
        XCTAssertEqual(back, state)
    }

    // MARK: - Guards

    func test_gradleDeleteCache_refusesPathsThatLeaveTheCacheDir() async {
        let service = GradleDaemonService()
        for name in ["", ".", "..", "../x", "a/b"] {
            let ok = await service.deleteCache(name: name)
            XCTAssertFalse(ok, name)
        }
    }

    func test_derivedDataDelete_refusesAnythingButADirectChild() {
        let service = DerivedDataService()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/DerivedData").path
        XCTAssertTrue(service.isEntry(root + "/Foo-abc"))
        XCTAssertFalse(service.isEntry(root))
        XCTAssertFalse(service.isEntry(root + "/Foo-abc/Build"))
        XCTAssertFalse(service.isEntry(root + "/../x"))
        XCTAssertFalse(service.isEntry("/tmp"))
    }

    // MARK: - Connector configuration

    @MainActor
    func test_configuredAreas_readEnvironmentThenDefaults() {
        let defaults = UserDefaults(suiteName: "jaca-test-\(UUID().uuidString)")!
        defaults.set(["gradle", "bogus"], forKey: DaemonConnector.areasKey)
        XCTAssertEqual(DaemonConnector.configuredAreas(environment: [:], defaults: defaults), [.gradle])
        XCTAssertEqual(DaemonConnector.configuredAreas(environment: ["JACA_DAEMON_AREAS": "xcode, projects"], defaults: defaults),
                       [.xcode, .projects])
        XCTAssertEqual(DaemonConnector.configuredAreas(environment: ["JACA_DAEMON_AREAS": "all"], defaults: defaults),
                       Set(DaemonArea.allCases))
    }

    // MARK: - Network wiring

    /// The override services reach every new capture in both modes. Under MITM a rule fires on
    /// the device proxy, so the services must not depend on the mode.
    @MainActor
    func test_networkCaptures_getOverrideServicesInBothModes() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ov-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("JACA_OVERRIDES_DIR", dir.path, 1)
        defer {
            unsetenv("JACA_OVERRIDES_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        let daemon = try TestDaemon()
        let overrides = OverridesEngine()
        let captures = NetworkArea.Captures(bus: daemon.server.bus, bodyCache: nil)
        let controller = NetworkModeController(captures: captures, bus: daemon.server.bus,
                                               store: .memory(.agentHTTPSDebugging), settle: {})
        NetworkArea.install(on: daemon.server, captures: captures, controller: controller,
                            interceptServices: DaemonAreas.interceptServices(from: overrides))

        XCTAssertNotNil(captures.interceptServices(), "agent mode")
        await controller.setMode(.mitmHTTPSDebugging)
        XCTAssertEqual(controller.mode, .mitmHTTPSDebugging)
        XCTAssertNotNil(captures.interceptServices(), "mitm mode")
        await controller.setMode(.agentHTTPSDebugging)
        XCTAssertNotNil(captures.interceptServices(), "back in agent mode")
    }

    // MARK: - End to end

    @MainActor
    func test_connector_callsGradleListOnTheDaemon() async throws {
        let daemon = try TestDaemon()
        GradleArea.install(on: daemon.server)
        let connector = DaemonConnector(paths: daemon.paths, executable: nil, enabledAreas: [.gradle])
        let list = await connector.call("gradle.list", as: [GradleDaemon].self)
        XCTAssertNotNil(list, "reached the daemon")
        guard case .connected = connector.state else { return XCTFail("state \(connector.state)") }
    }

    @MainActor
    func test_connector_reportsUnavailableWithoutSpawnableDaemon() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jd-\(UUID().uuidString.prefix(8))")
        let connector = DaemonConnector(paths: DaemonPaths(directory: dir), executable: nil, enabledAreas: [.gradle])
        let list = await connector.call("gradle.list", as: [GradleDaemon].self)
        XCTAssertNil(list)
        guard case .unavailable = connector.state else { return XCTFail("state \(connector.state)") }
    }

    @MainActor
    func test_projectsArea_publishesStateAndManagesUserFolders() async throws {
        let suite = "jaca-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("claude/projects"), withIntermediateDirectories: true)
        let folder = tmp.appendingPathComponent("MyFolder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let engine = ProjectsEngine(defaults: defaults,
                                    scanner: ProjectsScanner(claudeHome: tmp.appendingPathComponent("claude")),
                                    cache: ProjectsCache(fileURL: tmp.appendingPathComponent("projects.json")))
        let daemon = try TestDaemon()
        ProjectsArea.install(on: daemon.server, engine: engine)
        let client = try await daemon.client()
        var events = try await client.subscribe([ProjectsArea.stateTopic]).makeAsyncIterator()
        let initial = try await events.next()?.decode(ProjectsState.self)
        XCTAssertEqual(initial?.projects, [])

        let added: Bool = try await client.call("projects.addFolder", ProjectsArea.PathParams(path: folder.path))
        XCTAssertTrue(added)
        let again: Bool = try await client.call("projects.addFolder", ProjectsArea.PathParams(path: folder.path))
        XCTAssertFalse(again, "already added")
        XCTAssertEqual(defaults.stringArray(forKey: ProjectsEngine.userFoldersKey), [folder.path])

        // The add triggers a scan; wait for the generation that includes the folder.
        var scanned: ProjectsState?
        while let event = await events.next() {
            let state = try event.decode(ProjectsState.self)
            if state.scanGeneration >= 1 && !state.isRefreshing { scanned = state; break }
        }
        XCTAssertEqual(scanned?.projects.map(\.path), [folder.path])

        let removed: String? = try await client.call("projects.removeFolder", ProjectsArea.IDParams(id: folder.path))
        XCTAssertEqual(removed, "MyFolder")
        XCTAssertEqual(defaults.stringArray(forKey: ProjectsEngine.userFoldersKey), [])
    }
}

/// A provider that emits a fixed list, so discovery is testable without adb or simctl.
private struct FixedProvider: DeviceProvider {
    let platform: DevicePlatform
    let devices: [Device]
    func deviceStream() -> AsyncStream<[Device]> {
        AsyncStream { c in c.yield(devices) }
    }
}

/// Reports one device on the first discovery pass and none after (it was unplugged).
private final class UnpluggingProvider: DeviceProvider, @unchecked Sendable {
    let platform = DevicePlatform.android
    private let lock = NSLock()
    private var passes = 0
    func deviceStream() -> AsyncStream<[Device]> {
        let pass = lock.withLock { passes += 1; return passes }
        let devices = pass == 1 ? [Device(id: "emu-1", platform: .android, model: "Pixel", state: .connected)] : []
        return AsyncStream { c in c.yield(devices) }
    }
}

final class DevicesAreaTests: XCTestCase {
    func test_device_unknownStateAndPlatformDecodeTolerantly() throws {
        let d = try JSONDecoder.daemon.decode(Device.self, from: Data(#"{"id":"emu-1","platform":"tv","state":"sleeping"}"#.utf8))
        XCTAssertEqual(d.id, "emu-1")
        XCTAssertEqual(d.platform, .android)
        XCTAssertEqual(d.state, .unknown)
        XCTAssertEqual(d.model, "")
    }

    @MainActor
    func test_devicesArea_publishesMergedListWhileSubscribed() async throws {
        let engine = DevicesEngine(defaults: .standard) { _ in [
            FixedProvider(platform: .iosSimulator, devices: [Device(id: "sim-1", platform: .iosSimulator, model: "iPhone", state: .booted)]),
            FixedProvider(platform: .android, devices: [Device(id: "emu-1", platform: .android, model: "Pixel", state: .connected)]),
        ] }
        let daemon = try TestDaemon()
        DevicesArea.install(on: daemon.server, engine: engine)
        XCTAssertFalse(engine.isRunning, "discovery waits for a subscriber")

        let client = try await daemon.client()
        var events = try await client.subscribe([DevicesArea.listTopic]).makeAsyncIterator()
        var ids: [String] = []
        while ids.count < 2, let event = await events.next() {
            ids = try event.decode([Device].self).map(\.id)
        }
        XCTAssertEqual(ids, ["emu-1", "sim-1"], "ordered by platform")
        XCTAssertTrue(engine.isRunning)
    }

    /// `devices.apps` with nobody watching the list: the lookup runs discovery once, then stops it.
    @MainActor
    func test_deviceLookup_runsDiscoveryOnceWhenNobodyWatches() async {
        let engine = DevicesEngine(defaults: .standard) { _ in [
            FixedProvider(platform: .android, devices: [Device(id: "emu-1", platform: .android, model: "Pixel", state: .connected)]),
        ] }
        let found = await engine.device("emu-1")
        XCTAssertEqual(found?.id, "emu-1")
        XCTAssertFalse(engine.isRunning, "a one-off lookup doesn't leave discovery running")
        let missing = await engine.device("nope", timeout: .milliseconds(200))
        XCTAssertNil(missing)
    }

    /// A lookup never answers from what an earlier lookup saw: the device may be gone.
    @MainActor
    func test_deviceLookup_doesNotReuseAStaleList() async {
        let provider = UnpluggingProvider()
        let engine = DevicesEngine(defaults: .standard) { _ in [provider] }
        let first = await engine.device("emu-1")
        XCTAssertEqual(first?.id, "emu-1")
        let gone = await engine.device("emu-1", timeout: .milliseconds(300))
        XCTAssertNil(gone, "the second discovery pass no longer sees the device")
    }
}
