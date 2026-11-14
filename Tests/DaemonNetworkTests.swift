import XCTest
@testable import Jaca

@MainActor
final class DaemonNetworkTests: XCTestCase {
    private let device = Device(id: "emu-1", platform: .android, model: "Pixel", state: .connected)

    private func waitUntil(_ timeout: Duration = .seconds(3), _ cond: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !cond() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition not met in time") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func txn(_ i: Int, body: String? = nil) -> NetworkTransaction {
        var t = NetworkTransaction(method: "GET", url: "https://api.example.com/\(i)", host: "api.example.com",
                                   scheme: "https", requestHeaders: [HeaderPair(name: "Accept", value: "*/*")])
        t.statusCode = 200
        t.responseBody = body.map { Data($0.utf8) }
        t.responseBytes = t.responseBody?.count ?? 0
        t.finishedAt = t.startedAt.addingTimeInterval(0.1)
        return t
    }

    private let simulator = Device(id: "SIM-UDID-1", platform: .iosSimulator, model: "iPhone", state: .booted)

    /// The controllers `makeArea` made. `Captures.modeController` is weak, and `install` keeps
    /// the controller alive in production; without `install`, the test must keep it.
    private var controllers: [NetworkModeController] = []

    /// A capture area whose mode lives in memory, so the tests never change the user's setting.
    private func makeArea(_ daemon: TestDaemon, mode: NetworkInspectionMode, install: Bool = true)
        -> (NetworkArea.Captures, NetworkModeController, NetworkModeStore) {
        let captures = NetworkArea.Captures(bus: daemon.server.bus, bodyCache: nil)
        captures.loadCA = { nil }
        let store = NetworkModeStore.memory(mode)
        let controller = NetworkModeController(captures: captures, bus: daemon.server.bus, store: store, settle: {})
        controllers.append(controller)
        if install { NetworkArea.install(on: daemon.server, captures: captures, controller: controller) }
        return (captures, controller, store)
    }

    private func running(_ id: UUID, _ device: Device, _ sourceID: String, _ package: String? = nil) -> NetworkArea.RunningCapture {
        NetworkArea.RunningCapture(id: id, device: device, sourceID: sourceID, package: package)
    }

    /// A capture starting on an app stops the other running captures of that app on that device:
    /// the app's agent serves one at a time, and two take its connection from each other.
    func test_aNewAgentCaptureStopsTheOthersOfTheSameApp() {
        let new = UUID(), sameApp = UUID(), otherApp = UUID(), otherDevice = UUID()
        let other = Device(id: "emu-2", platform: .android, model: "Pixel", state: .connected)
        let list = [running(sameApp, device, "agent", "com.example.app"),
                    running(otherApp, device, "agent", "com.example.other"),
                    running(otherDevice, other, "agent", "com.example.app")]
        let agent = AgentHTTPDebugging()
        XCTAssertEqual(NetworkArea.capturesToStop(running: list, starting: new, on: device, sourceID: "agent",
                                                  package: "com.example.app", strategy: agent), [sameApp])
        XCTAssertEqual(NetworkArea.capturesToStop(running: list, starting: new, on: device, sourceID: "agent",
                                                  package: nil, strategy: agent), [],
                       "a capture with no app chosen replaced another")
    }

    /// `select mitm` stops another device proxy, and the agent captures, on the same device. It
    /// leaves other devices and This Mac's browser alone.
    func test_aDeviceProxyStopsEveryOtherClaimOnItsDevice() {
        let new = UUID(), otherProxy = UUID(), agent = UUID(), otherDevice = UUID(), browser = UUID()
        let other = Device(id: "emu-2", platform: .android, model: "Pixel", state: .connected)
        let list = [running(otherProxy, device, "mitm"),
                    running(agent, device, "agent", "com.example.app"),
                    running(otherDevice, other, "mitm"),
                    running(browser, .thisMac, "browser")]
        let stop = NetworkArea.capturesToStop(running: list, starting: new, on: device, sourceID: "mitm",
                                              package: nil, strategy: MITMHTTPDebugging())
        XCTAssertEqual(Set(stop), [otherProxy, agent])
    }

    /// Two simulators share the Mac system proxy, so one simulator's capture never stops another's.
    func test_simulatorProxyCaptures_onTwoSimulators_bothKeepRunning() {
        let new = UUID(), other = UUID()
        let second = Device(id: "SIM-UDID-2", platform: .iosSimulator, model: "iPad", state: .booted)
        let stop = NetworkArea.capturesToStop(running: [running(other, second, "mitm")], starting: new, on: simulator,
                                              sourceID: "mitm", package: nil, strategy: MITMHTTPDebugging())
        XCTAssertEqual(stop, [])
    }

    func test_networkMode_roundTripsAndPublishesTheRetainedTopic() async throws {
        let daemon = try TestDaemon()
        let (_, controller, store) = makeArea(daemon, mode: .agentHTTPSDebugging)
        let client = try await daemon.client()

        let initial: NetworkModeController.State = try await client.call("network.mode")
        XCTAssertEqual(initial, NetworkModeController.State(mode: "agent", switching: false))
        var events = try await client.subscribe([NetworkModeController.topic]).makeAsyncIterator()
        let retained = try await events.next()?.decode(NetworkModeController.State.self)
        XCTAssertEqual(retained, initial, "a new subscriber gets the last mode")

        let _: RPCEmpty = try await client.call("network.setMode", NetworkArea.SetModeParams(mode: "mitm"))
        var seen: [NetworkModeController.State] = []
        while let event = await events.next() {
            let state = try event.decode(NetworkModeController.State.self)
            seen.append(state)
            if state.mode == "mitm" && !state.switching { break }
        }
        XCTAssertEqual(seen, [NetworkModeController.State(mode: "agent", switching: true),
                              NetworkModeController.State(mode: "mitm", switching: false)])
        let after: NetworkModeController.State = try await client.call("network.mode")
        XCTAssertEqual(after, NetworkModeController.State(mode: "mitm", switching: false))
        XCTAssertEqual(store.read(), .mitmHTTPSDebugging, "the switch persisted")
        XCTAssertEqual(controller.mode, .mitmHTTPSDebugging)
        XCTAssertFalse(controller.isSwitching)
    }

    func test_setMode_withAnUnknownName_isInvalidParams() async throws {
        let daemon = try TestDaemon()
        let (_, controller, store) = makeArea(daemon, mode: .agentHTTPSDebugging)
        let client = try await daemon.client()
        do {
            let _: RPCEmpty = try await client.call("network.setMode", NetworkArea.SetModeParams(mode: "proxy"))
            XCTFail("an unknown mode was accepted")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.invalidParamsCode)
            XCTAssertEqual(error.message, "Unknown mode. Use agent or mitm.")
        }
        XCTAssertEqual(store.read(), .agentHTTPSDebugging)
        XCTAssertEqual(controller.mode, .agentHTTPSDebugging)
    }

    /// A switch to MITM stops an Android agent capture and shows its chooser, because MITM does
    /// not offer the agent there. This Mac's browser capture is offered in both modes and keeps
    /// running. (The agent tab is restored, not running: a running agent needs a real device.
    /// The plan does not depend on whether a tab runs.)
    func test_switchToMITM_reopensTheAgentChooser_andKeepsTheBrowserRunning() async throws {
        let daemon = try TestDaemon()
        let (captures, controller, _) = makeArea(daemon, mode: .agentHTTPSDebugging, install: false)
        let agentTab = UUID(), browserTab = UUID()
        _ = captures.open(NetworkArea.OpenParams(id: agentTab, device: device, sourceID: "agent",
                                                 package: "com.example.app", autoStart: false))
        _ = captures.open(NetworkArea.OpenParams(id: browserTab, device: .thisMac, sourceID: "browser",
                                                 package: nil, autoStart: true))
        let agentEngine = try captures.session(agentTab).engine
        let browserEngine = try captures.session(browserTab).engine
        XCTAssertTrue(agentEngine.state.hasSelectedMode)
        XCTAssertEqual(agentEngine.state.offeredSourceIDs, ["agent"])
        let browserWasRunning = browserEngine.state.isRunning

        await controller.setMode(.mitmHTTPSDebugging)

        XCTAssertFalse(agentEngine.state.hasSelectedMode, "the agent tab shows its chooser")
        XCTAssertFalse(agentEngine.state.isRunning)
        XCTAssertEqual(agentEngine.state.offeredSourceIDs, ["mitm"])
        XCTAssertTrue(browserEngine.state.hasSelectedMode)
        XCTAssertEqual(browserEngine.state.selectedSourceID, "browser")
        XCTAssertEqual(browserEngine.state.isRunning, browserWasRunning, "the browser capture was touched")
        XCTAssertEqual(browserEngine.state.offeredSourceIDs, ["browser"])
        browserEngine.stop()
    }

    /// Under MITM, jacad refuses the agent on Android, and companion capture everywhere.
    func test_selectAgent_onAndroid_inMITMMode_isRejected() async throws {
        let daemon = try TestDaemon()
        let (captures, _, _) = makeArea(daemon, mode: .mitmHTTPSDebugging, install: false)
        let id = UUID()
        _ = captures.open(NetworkArea.OpenParams(id: id, device: device, sourceID: nil, package: nil, autoStart: false))
        XCTAssertThrowsError(try captures.select(id, sourceID: "agent", package: "com.example.app")) { error in
            XCTAssertEqual(error as? RPCError, .invalidParams(
                "This capture source isn't available in the current network inspection mode."))
        }
        XCTAssertThrowsError(try captures.select(id, sourceID: "companion", package: nil)) { error in
            XCTAssertEqual(error as? RPCError, .invalidParams("Companion capture runs in the app, not in jacad."))
        }
        let state = try captures.session(id).engine.state
        XCTAssertFalse(state.hasSelectedMode)
        XCTAssertFalse(state.isRunning)
    }

    /// A tab restored with a source the mode no longer offers opens at the chooser.
    func test_open_dropsARestoredSourceTheModeDoesNotOffer() async throws {
        let daemon = try TestDaemon()
        let (captures, _, _) = makeArea(daemon, mode: .mitmHTTPSDebugging, install: false)
        let id = UUID()
        _ = captures.open(NetworkArea.OpenParams(id: id, device: device, sourceID: "agent",
                                                 package: "com.example.app", autoStart: true))
        let state = try captures.session(id).engine.state
        XCTAssertFalse(state.hasSelectedMode)
        XCTAssertFalse(state.isRunning)
        XCTAssertFalse(state.isConnecting, "an unoffered source started its precheck")
        XCTAssertEqual(state.offeredSourceIDs, ["mitm"])
    }

    func test_installCA_routesByDevice() async throws {
        let daemon = try TestDaemon()
        let (captures, _, _) = makeArea(daemon, mode: .mitmHTTPSDebugging, install: false)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ca-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ca = try CertificateAuthority(directory: dir)
        captures.loadCA = { ca }
        captures.resolveADB = { URL(fileURLWithPath: "/fake/adb") }
        let calls = CallLog()
        captures.caInstall = NetworkCAInstall(
            androidRooted: { _, serial, pem in
                calls.add("rooted \(serial) \(FileManager.default.fileExists(atPath: pem.path))")
                return .notRooted
            },
            androidPush: { _, serial, _ in calls.add("push \(serial)"); return true },
            simulatorInstall: { udid, pem in calls.add("sim \(udid) \(pem == ca.rootCertificatePEM)"); return .success(()) },
            simulatorReboot: { udid in calls.add("reboot \(udid)"); return .success(()) })

        let android = UUID(), sim = UUID(), mac = UUID()
        _ = captures.open(NetworkArea.OpenParams(id: android, device: device, sourceID: nil, package: nil, autoStart: false))
        _ = captures.open(NetworkArea.OpenParams(id: sim, device: simulator, sourceID: nil, package: nil, autoStart: false))
        _ = captures.open(NetworkArea.OpenParams(id: mac, device: .thisMac, sourceID: nil, package: nil, autoStart: false))

        let onAndroid = try await captures.installCA(android)
        XCTAssertEqual(onAndroid, NetworkArea.InstallCAResult(outcome: .needsUser))
        let onSimulator = try await captures.installCA(sim)
        XCTAssertEqual(onSimulator, NetworkArea.InstallCAResult(outcome: .installed, rebootAdvised: true))
        try await captures.rebootSimulator(sim)
        let onMac = try await captures.installCA(mac)
        XCTAssertEqual(onMac.outcome, .failed)
        do {
            try await captures.rebootSimulator(android)
            XCTFail("rebooted an Android device")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.invalidParamsCode)
        }
        XCTAssertEqual(calls.entries, ["rooted emu-1 true", "push emu-1", "sim SIM-UDID-1 true", "reboot SIM-UDID-1"])
    }

    func test_installCAResult_mapsEachAndroidOutcome() {
        XCTAssertEqual(NetworkArea.installCAResult(android: .installed, pushed: nil).outcome, .installed)
        XCTAssertEqual(NetworkArea.installCAResult(android: .notRooted, pushed: true).outcome, .needsUser)
        XCTAssertEqual(NetworkArea.installCAResult(android: .notRooted, pushed: false),
                       NetworkArea.InstallCAResult(outcome: .failed, message: "Couldn't copy the certificate to the device."))
        XCTAssertEqual(NetworkArea.installCAResult(android: .failed("boom"), pushed: nil),
                       NetworkArea.InstallCAResult(outcome: .failed, message: "boom"))
        XCTAssertEqual(NetworkArea.installCAResult(simulator: .failure(SimulatorCAError(message: "not booted"))),
                       NetworkArea.InstallCAResult(outcome: .failed, message: "not booted"))
    }

    /// jacad reads the CA when a source first needs it, once it loads. Without one, the capture
    /// says so and opens no Chrome.
    func test_macCapture_readsTheCAOnce_andReportsAMissingOne() throws {
        let daemon = try TestDaemon()
        let captures = NetworkArea.Captures(bus: daemon.server.bus, bodyCache: nil)
        var reads = 0
        captures.loadCA = { reads += 1; return nil }
        _ = captures.open(NetworkArea.OpenParams(id: UUID(), device: device, sourceID: nil, package: nil, autoStart: false))
        XCTAssertEqual(reads, 0, "an agent capture read the CA")

        let id = UUID()
        _ = captures.open(NetworkArea.OpenParams(id: id, device: .thisMac, sourceID: "browser", package: nil, autoStart: true))
        XCTAssertEqual(reads, 1)
        let state = try XCTUnwrap(captures.sessions[id]?.engine.state)
        XCTAssertEqual(state.selectedSourceID, "browser")
        XCTAssertEqual(state.statusMessage, "Couldn’t read Jaca’s certificate. Check ~/.jaca/jacad.log.")
        try captures.session(id).engine.stop()
    }

    func test_transaction_roundTripsAndStripsBodies() throws {
        let t = txn(1, body: "{\"ok\":true}")
        let back = try JSONDecoder.daemon.decode(NetworkTransaction.self, from: JSONEncoder.daemon.encode(t))
        XCTAssertEqual(back.id, t.id)
        XCTAssertEqual(back.responseBody, t.responseBody)
        XCTAssertEqual(back.requestHeaders, t.requestHeaders)
        let stripped = t.strippingBodies()
        XCTAssertNil(stripped.responseBody)
        XCTAssertTrue(stripped.bodiesEvicted)
        XCTAssertFalse(txn(2).strippingBodies().bodiesEvicted, "nothing to fetch when there was no body")
    }

    func test_remoteTab_receivesUpsertsAndFetchesBodiesOnDemand() async throws {
        let daemon = try TestDaemon()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A private body cache: the default one is jacad's real folder, wiped on creation.
        let cache = NetworkBodyCache(directory: dir.appendingPathComponent("bodies"))
        let captures = NetworkArea.Captures(bus: daemon.server.bus, bodyCache: cache, bodiesInMemory: 2)
        NetworkArea.install(on: daemon.server, captures: captures)
        let connector = DaemonConnector(paths: daemon.paths, executable: nil, enabledAreas: [.network])
        let ca = try CertificateAuthority(directory: dir)

        let id = UUID()
        let feed = RemoteNetworkFeed(id: id, device: device, autoStart: false, daemon: connector)
        let tab = NetworkSession(id: id, device: device, feed: feed, ca: ca, adbURL: nil, isRemote: true)
        try await waitUntil { captures.sessions[id] != nil }
        let engine = try XCTUnwrap(captures.sessions[id]?.engine)

        // The capture source reports transactions (a real agent would); an update upserts by id.
        var first = txn(0, body: "zero")
        engine.capture(didReceive: first)
        for i in 1...3 { engine.capture(didReceive: txn(i, body: "body-\(i)")) }
        first.statusCode = 304
        engine.capture(didReceive: first)
        try await waitUntil { tab.transactions.count == 4 && tab.transactions.first?.statusCode == 304 }
        XCTAssertTrue(tab.transactions.allSatisfy { $0.responseBody == nil && $0.bodiesEvicted }, "bodies stay in the daemon")
        XCTAssertTrue(tab.caReady, "an HTTPS transaction confirms the CA")

        // Selecting the oldest fetches its body; it was spilled to the daemon's disk cache.
        tab.selectedID = first.id
        try await waitUntil { tab.selected?.responseBody != nil }
        XCTAssertEqual(tab.selected?.responseBody, Data("zero".utf8))

        let har = await tab.harData()
        XCTAssertNotNil(har)

        // Relaunch: a tab with the same id attaches and resyncs the list.
        let feed2 = RemoteNetworkFeed(id: id, device: device, autoStart: false, daemon: connector)
        let tab2 = NetworkSession(id: id, device: device, feed: feed2, ca: ca, adbURL: nil, isRemote: true)
        try await waitUntil { tab2.transactions.count == 4 }

        tab2.close()
        try await waitUntil { captures.sessions[id] == nil }
    }

    /// Two quick updates to a row outside the in-memory window spill in order: the cache ends up
    /// with the newer bodies, never the older ones landing last.
    func test_spillsOfOneRow_landInOrder() async throws {
        let daemon = try TestDaemon()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try XCTUnwrap(NetworkBodyCache(directory: dir))
        let captures = NetworkArea.Captures(bus: daemon.server.bus, bodyCache: cache, bodiesInMemory: 1)
        let id = UUID()
        _ = captures.open(NetworkArea.OpenParams(id: id, device: device, sourceID: nil, package: nil, autoStart: false))
        let engine = try XCTUnwrap(captures.sessions[id]?.engine)

        var row = txn(0, body: "v1")
        engine.capture(didReceive: row)
        engine.capture(didReceive: txn(1, body: "other"))   // pushes row 0 out of the window
        for version in 2...5 {
            row.responseBody = Data("v\(version)".utf8)
            engine.capture(didReceive: row)
        }
        try await waitUntil {
            captures.sessions[id]?.transactions.first?.bodiesEvicted == true
        }
        let stored = await cache.load(row.id)
        XCTAssertEqual(stored.resp, Data("v5".utf8))
    }

    func test_agentCapture_onMissingDevice_reportsThroughTheDaemon() async throws {
        guard let adb = AndroidToolchain.adbURL() else { throw XCTSkip("needs adb") }
        let daemon = try TestDaemon()
        let captures = NetworkArea.Captures(bus: daemon.server.bus, bodyCache: nil)
        NetworkArea.install(on: daemon.server, captures: captures)
        let connector = DaemonConnector(paths: daemon.paths, executable: nil, enabledAreas: [.network])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nb-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ca = try XCTUnwrap(try? CertificateAuthority(directory: dir))
        let ghost = Device(id: "no-such-device-zzz", platform: .android, model: "Ghost", state: .connected)

        let id = UUID()
        let feed = RemoteNetworkFeed(id: id, device: ghost, autoStart: false, daemon: connector)
        let tab = NetworkSession(id: id, device: ghost, feed: feed, ca: ca, adbURL: adb, isRemote: true)
        try await waitUntil { captures.sessions[id] != nil }
        tab.startAgentCapture(package: "com.example.missing")
        try await waitUntil(.seconds(8)) { tab.statusMessage != nil && !tab.isConnecting }
        XCTAssertFalse(tab.isRunning)
        tab.close()
    }
}

/// Records the installer calls of a test, from any thread.
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ entry: String) { lock.withLock { list.append(entry) } }
    var entries: [String] { lock.withLock { list } }
}
