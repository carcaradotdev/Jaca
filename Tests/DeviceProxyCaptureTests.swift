import XCTest
@testable import Jaca

/// The Android device proxy source: the order of its device changes on start and stop, the
/// release gate, and the lease check. adb is a fake that keeps one `http_proxy` value; the
/// proxy is a real `ProxyServer` on loopback.
@MainActor
final class DeviceProxyCaptureTests: XCTestCase {
    private var dir: URL!
    private var ledger: JSONLedgerFile<DeviceProxyLedger.Entry>!
    private var gate: DeviceReleaseGate!
    private var adb: FakeAdb!
    private var device: Device!
    private let adbURL = URL(fileURLWithPath: "/fake/adb")
    private let ownPid: Int32 = 4_100

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-device-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ledger = JSONLedgerFile(fileURL: dir.appendingPathComponent("device-proxies.json"))
        gate = DeviceReleaseGate()
        // A serial per test, so the process-wide armed-port table never mixes tests.
        device = Device(id: "emulator-\(UUID().uuidString.prefix(8))", platform: .android,
                        model: "Pixel", state: .connected)
        adb = FakeAdb(serial: device.id, ledger: ledger)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func environment(alive: Set<Int32> = []) -> DeviceProxyEnvironment {
        let adb = self.adb!
        let live = alive.union([ownPid])
        return DeviceProxyEnvironment(
            run: { _, arguments in await adb.handle(arguments) },
            pause: { _ in },
            pidAlive: { live.contains($0) },
            ownPid: ownPid,
            now: { Date() },
            isExecutable: { _ in true },
            cleanup: .none)
    }

    private func makeSource(ca: CertificateAuthority?) -> DeviceProxyCaptureSource {
        DeviceProxyCaptureSource(device: device, adbURL: adbURL, ca: ca, intercept: nil,
                                 environment: environment(), ledger: ledger, gate: gate)
    }

    private func makeCA() throws -> CertificateAuthority {
        try CertificateAuthority(directory: dir.appendingPathComponent("ca", isDirectory: true),
                                 allowKeychainMigration: false)
    }

    // MARK: - Start

    func test_start_writesTheLedgerThenAddsTheReverseThenSetsTheProxy() async throws {
        let source = makeSource(ca: try makeCA())
        let sink = RecordingSink()
        source.start(into: sink)
        await source.armTask?.value

        XCTAssertEqual(adb.events, ["read", "reverse-add ledger=yes", "arm"])
        let port = try XCTUnwrap(sink.ports.last)
        XCTAssertGreaterThan(port, 0)
        XCTAssertEqual(adb.proxy, "127.0.0.1:\(port)")
        XCTAssertEqual(sink.statuses.first, "Setting the device proxy…")
        XCTAssertEqual(sink.statuses.last, "Capturing this device through Jaca's proxy")
        let entry = try XCTUnwrap(DeviceProxyLedger.entry(serial: device.id, port: port, in: ledger))
        XCTAssertEqual(entry.value, "127.0.0.1:\(port)")
        XCTAssertNil(entry.previous)
        XCTAssertEqual(entry.pid, ownPid)

        source.stop()
        await source.teardownTask?.value
    }

    func test_start_withoutACA_saysSoAndTouchesNothing() async {
        let source = makeSource(ca: nil)
        let sink = RecordingSink()
        source.start(into: sink)
        await source.armTask?.value
        XCTAssertEqual(sink.statuses, ["Couldn’t read Jaca’s certificate. Check ~/.jaca/jacad.log."])
        XCTAssertEqual(adb.events, [])
    }

    func test_start_whenTheReverseFails_rollsBackAndDropsTheLedgerEntry() async throws {
        adb.failReverse = true
        let source = makeSource(ca: try makeCA())
        let sink = RecordingSink()
        source.start(into: sink)
        await source.armTask?.value
        await source.teardownTask?.value

        XCTAssertFalse(adb.events.contains("arm"), "the proxy must not be set without the reverse")
        XCTAssertTrue(sink.statuses.last??.hasPrefix("Couldn’t start the proxy: ") ?? false)
        XCTAssertNil(adb.proxy)
        XCTAssertEqual(DeviceProxyLedger.load(in: ledger), [])
    }

    // MARK: - Stop

    func test_stop_clearsTheProxyThenRemovesTheReverseThenTheLedgerEntry() async throws {
        let source = makeSource(ca: try makeCA())
        source.start(into: RecordingSink())
        await source.armTask?.value
        adb.events.removeAll()

        source.stop()
        await source.teardownTask?.value

        XCTAssertEqual(adb.events, ["read", "clear", "read", "reverse-remove ledger=yes"])
        XCTAssertNil(adb.proxy)
        XCTAssertEqual(DeviceProxyLedger.load(in: ledger), [])
    }

    func test_stop_restoresTheProxyTheDeviceHadBefore() async throws {
        adb.proxy = "10.0.0.5:8888"
        let source = makeSource(ca: try makeCA())
        source.start(into: RecordingSink())
        await source.armTask?.value
        XCTAssertEqual(DeviceProxyLedger.load(in: ledger).first?.previous, "10.0.0.5:8888")
        adb.events.removeAll()

        source.stop()
        await source.teardownTask?.value

        XCTAssertEqual(adb.events, ["read", "restore 10.0.0.5:8888", "read", "reverse-remove ledger=yes"])
        XCTAssertEqual(adb.proxy, "10.0.0.5:8888")
        XCTAssertEqual(DeviceProxyLedger.load(in: ledger), [])
    }

    func test_stop_whenTheRevertDoesNotTakeEffect_keepsTheEntryAndSaysSo() async throws {
        let source = makeSource(ca: try makeCA())
        let sink = RecordingSink()
        source.start(into: sink)
        await source.armTask?.value
        adb.ignoresWrites = true

        source.stop()
        await source.teardownTask?.value

        XCTAssertEqual(sink.statuses.last, "Couldn’t remove the device proxy. Use Revert in the sidebar.")
        let entries = DeviceProxyLedger.load(in: ledger)
        XCTAssertEqual(entries.count, 1, "the entry stays for reconcile")
        XCTAssertEqual(entries.first?.released, true, "no capture holds it, so Revert and reconcile may repair it")
    }

    /// Compare-and-restore: a device that reads another value at stop is left as it is.
    func test_stop_leavesAProxySomebodyElseSetSinceTheStart() async throws {
        let source = makeSource(ca: try makeCA())
        source.start(into: RecordingSink())
        await source.armTask?.value
        adb.proxy = "proxy.corp.example:3128"
        adb.events.removeAll()

        source.stop()
        await source.teardownTask?.value

        XCTAssertEqual(adb.events, ["read", "reverse-remove ledger=yes"])
        XCTAssertEqual(adb.proxy, "proxy.corp.example:3128")
        XCTAssertEqual(DeviceProxyLedger.load(in: ledger), [])
    }

    /// Two device proxy captures overlap on one device. Stopping both, in either order, must not
    /// leave the device on a dead `127.0.0.1` proxy.
    func test_overlappingCaptures_stopInStartOrder_leaveTheDeviceClear() async throws {
        let ca = try makeCA()
        let first = makeSource(ca: ca)
        first.start(into: RecordingSink())
        await first.armTask?.value
        let second = makeSource(ca: ca)
        second.start(into: RecordingSink())
        await second.armTask?.value
        XCTAssertTrue(DeviceProxyPlan.isLoopbackValue(adb.proxy ?? ""))

        first.stop()
        await first.teardownTask?.value
        XCTAssertTrue(DeviceProxyPlan.isLoopbackValue(adb.proxy ?? ""), "the second capture keeps its proxy")

        second.stop()
        await second.teardownTask?.value
        XCTAssertNil(adb.proxy, "the first capture's dead loopback value is not restored")
        XCTAssertEqual(DeviceProxyLedger.load(in: ledger), [])
    }

    func test_settle_waitsForTheStopTask() async throws {
        let source = makeSource(ca: try makeCA())
        source.start(into: RecordingSink())
        await source.armTask?.value
        adb.reverseRemoveLatch = Latch()

        source.stop()
        XCTAssertTrue(gate.isPending(serial: device.id))
        let settled = Flag()
        let gate = self.gate!, serial = device.id
        let waiter = Task { @MainActor in
            await gate.settle(serial: serial)
            settled.set()
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(settled.value, "settle returned before the teardown finished")

        adb.reverseRemoveLatch?.open()
        await waiter.value
        XCTAssertTrue(settled.value)
        XCTAssertEqual(DeviceProxyLedger.load(in: ledger), [])
    }

    // MARK: - Precheck and lease

    func test_precheck_refusesWhenAnotherLiveProcessHoldsTheProxy() async {
        DeviceProxyLedger.add(DeviceProxyLedger.Entry(
            serial: device.id, adbPath: adbURL.path, port: 5_555, value: "127.0.0.1:5555",
            previous: nil, pid: 7_777), in: ledger)
        adb.proxy = "127.0.0.1:5555"

        let message = await DeviceProxyCaptureSource.precheck(
            device: device, adbURL: adbURL, ledger: ledger, gate: gate,
            environment: environment(alive: [7_777]))

        XCTAssertEqual(message, "Another Jaca process is using this device's proxy. Stop that capture first.")
        XCTAssertEqual(adb.proxy, "127.0.0.1:5555", "a refusal must not touch the device")
        XCTAssertEqual(DeviceProxyLedger.load(in: ledger).count, 1)
    }

    func test_precheck_revertsAStaleEntryOfThisProcess() async {
        DeviceProxyLedger.add(DeviceProxyLedger.Entry(
            serial: device.id, adbPath: adbURL.path, port: 5_556, value: "127.0.0.1:5556",
            previous: "10.0.0.9:3128", pid: ownPid), in: ledger)
        adb.proxy = "127.0.0.1:5556"

        let message = await DeviceProxyCaptureSource.precheck(
            device: device, adbURL: adbURL, ledger: ledger, gate: gate, environment: environment())

        XCTAssertNil(message)
        XCTAssertEqual(adb.proxy, "10.0.0.9:3128")
        XCTAssertEqual(DeviceProxyLedger.load(in: ledger), [])
    }

    func test_precheck_revertsTheEntryOfADeadProcess() async {
        DeviceProxyLedger.add(DeviceProxyLedger.Entry(
            serial: device.id, adbPath: adbURL.path, port: 5_557, value: "127.0.0.1:5557",
            previous: nil, pid: 9_999), in: ledger)
        adb.proxy = "127.0.0.1:5557"

        let message = await DeviceProxyCaptureSource.precheck(
            device: device, adbURL: adbURL, ledger: ledger, gate: gate, environment: environment())

        XCTAssertNil(message)
        XCTAssertNil(adb.proxy)
        XCTAssertEqual(DeviceProxyLedger.load(in: ledger), [])
    }

    func test_precheck_offlineDevice_usesTheAgentMessage() async {
        adb.online = false
        let message = await DeviceProxyCaptureSource.precheck(
            device: device, adbURL: adbURL, ledger: ledger, gate: gate, environment: environment())
        XCTAssertEqual(message, "Pixel isn’t connected — plug it in and authorize USB debugging.")
    }

    func test_leaseVerdict() {
        let now = Date()
        func entry(port: Int, pid: Int32, age: TimeInterval = 0) -> DeviceProxyLedger.Entry {
            DeviceProxyLedger.Entry(serial: "s", adbPath: "/adb", port: port, value: "127.0.0.1:\(port)",
                                    previous: nil, pid: pid, createdAt: now.addingTimeInterval(-age))
        }
        let alive: (Int32) -> Bool = { $0 == 1 || $0 == 2 }
        let foreignLive = entry(port: 1, pid: 2)
        let foreignDead = entry(port: 2, pid: 3)
        let foreignOld = entry(port: 3, pid: 2, age: DeviceProxyLedger.staleAfter + 1)
        let ownArmed = entry(port: 4, pid: 1)
        let ownStale = entry(port: 5, pid: 1)

        XCTAssertEqual(DeviceProxyLease.verdict(entries: [foreignLive, ownStale], ownPid: 1, armedPorts: [],
                                                pidAlive: alive, now: now), .heldElsewhere)
        XCTAssertEqual(DeviceProxyLease.verdict(entries: [foreignDead, foreignOld, ownArmed, ownStale], ownPid: 1,
                                                armedPorts: [4], pidAlive: alive, now: now),
                       .free(ownStale: [ownStale]))
        XCTAssertEqual(DeviceProxyLease.verdict(entries: [], ownPid: 1, armedPorts: [], pidAlive: alive, now: now),
                       .free(ownStale: []))
        // A live process whose stop couldn't revert holds nothing.
        var released = foreignLive
        released.released = true
        XCTAssertEqual(DeviceProxyLease.verdict(entries: [released], ownPid: 1, armedPorts: [],
                                                pidAlive: alive, now: now), .free(ownStale: []))
    }

    // MARK: - Registry

    func test_registry_offersTheSourcesOfTheGivenMode() {
        let sim = Device(id: "SIM", platform: .iosSimulator, model: "iPhone", state: .booted)
        var companionOnly = Device(id: "c1", platform: .android, model: "Phone", state: .connected)
        companionOnly.isCompanion = true
        companionOnly.companionID = "c1"
        let agent = AgentHTTPDebugging(), mitm = MITMHTTPDebugging()
        func ids(_ d: Device, _ s: any HTTPDebuggingStrategy) -> [String] {
            CaptureSourceRegistry.options(for: d, context: nil, strategy: s).map(\.id)
        }

        XCTAssertEqual(ids(device, agent), ["agent"])
        XCTAssertEqual(ids(device, mitm), ["mitm"])
        XCTAssertEqual(ids(sim, agent), ["agent"])
        XCTAssertEqual(ids(sim, mitm), ["mitm"])
        XCTAssertEqual(ids(companionOnly, agent), [])
        XCTAssertEqual(ids(companionOnly, mitm), ["companion"])
        XCTAssertEqual(ids(.thisMac, mitm), ["browser"])
        XCTAssertEqual(CaptureSourceRegistry.defaultDescriptor(for: device, context: nil, strategy: mitm)?.id, "mitm")
    }

    func test_mitmDescriptor() throws {
        let d = try XCTUnwrap(CaptureSourceRegistry.descriptor(id: "mitm"))
        XCTAssertEqual(d.kind, .proxy)
        XCTAssertEqual(d.title, "Device proxy")
        XCTAssertEqual(d.detail, InterceptTransportID.mitmProxy.captureDetail)
        XCTAssertFalse(d.needsPackage)
    }

    // MARK: - Engine

    func test_state_decodesOldJSONWithoutOfferedSourceIDs() throws {
        let json = #"{"isRunning":true,"boundPort":4242,"selectedSourceID":"agent","hasSelectedMode":true}"#
        let state = try JSONDecoder().decode(NetworkCaptureState.self, from: Data(json.utf8))
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(state.boundPort, 4242)
        XCTAssertEqual(state.selectedSourceID, "agent")
        XCTAssertEqual(state.offeredSourceIDs, [])
    }

    func test_state_roundTripsOfferedSourceIDs() throws {
        var state = NetworkCaptureState()
        state.offeredSourceIDs = ["mitm"]
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(NetworkCaptureState.self, from: data).offeredSourceIDs, ["mitm"])
    }

    func test_restoreMode_unknownID_leavesTheChooserOpen() {
        let engine = NetworkCaptureEngine(device: device, adbURL: nil, ca: nil, companion: nil,
                                          deviceContext: { nil })
        engine.restoreMode(sourceID: "proxy", package: nil)
        XCTAssertFalse(engine.state.hasSelectedMode)
        XCTAssertNil(engine.state.selectedSourceID)
    }

    func test_restoreMode_keepsThePackageOnlyForASourceThatNeedsOne() {
        let engine = NetworkCaptureEngine(device: device, adbURL: nil, ca: nil, companion: nil,
                                          deviceContext: { nil })
        engine.restoreMode(sourceID: "mitm", package: "com.example")
        XCTAssertTrue(engine.state.hasSelectedMode)
        XCTAssertNil(engine.state.targetPackage)
        engine.restoreMode(sourceID: "agent", package: "com.example")
        XCTAssertEqual(engine.state.targetPackage, "com.example")
    }

    func test_engine_publishesTheOfferedSourceIDs() {
        let engine = NetworkCaptureEngine(device: .thisMac, adbURL: nil, ca: nil, companion: nil,
                                          deviceContext: { nil })
        XCTAssertEqual(engine.state.offeredSourceIDs, ["browser"])
    }

    func test_engine_readsTheCAWhenTheSourceIsBuilt() {
        let reads = Counter()
        _ = NetworkCaptureEngine(device: device, adbURL: nil, ca: { reads.increment(); return nil },
                                 companion: nil, deviceContext: { nil })
        XCTAssertEqual(reads.value, 0, "the CA must not be read before a source needs it")
    }
}

// MARK: - Fakes

/// adb for one device: keeps `http_proxy`, records the calls that change the device, and checks
/// the ledger at the moments the order tests care about.
private final class FakeAdb: @unchecked Sendable {
    private let lock = NSLock()
    private let serial: String
    private let ledger: JSONLedgerFile<DeviceProxyLedger.Entry>
    private var _proxy: String?
    private var _events: [String] = []
    private var _online = true
    private var _failReverse = false
    private var _ignoresWrites = false
    private var _latch: Latch?

    init(serial: String, ledger: JSONLedgerFile<DeviceProxyLedger.Entry>) {
        self.serial = serial
        self.ledger = ledger
    }

    var proxy: String? {
        get { locked { _proxy } }
        set { locked { _proxy = newValue } }
    }
    var events: [String] {
        get { locked { _events } }
        set { locked { _events = newValue } }
    }
    var online: Bool {
        get { locked { _online } }
        set { locked { _online = newValue } }
    }
    var failReverse: Bool {
        get { locked { _failReverse } }
        set { locked { _failReverse = newValue } }
    }
    /// The device ignores `settings put`, so a revert never takes effect.
    var ignoresWrites: Bool {
        get { locked { _ignoresWrites } }
        set { locked { _ignoresWrites = newValue } }
    }
    /// When set, `reverse --remove` waits for it to open.
    var reverseRemoveLatch: Latch? {
        get { locked { _latch } }
        set { locked { _latch = newValue } }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func record(_ event: String) { locked { _events.append(event) } }

    private func ok(_ stdout: String = "") -> CommandRunner.Result {
        CommandRunner.Result(exitCode: 0, stdout: stdout, stderr: "")
    }

    func handle(_ arguments: [String]) async -> CommandRunner.Result? {
        guard arguments.count >= 3, arguments[0] == "-s", arguments[1] == serial else {
            return CommandRunner.Result(exitCode: 1, stdout: "", stderr: "unexpected call")
        }
        let rest = Array(arguments.dropFirst(2))
        if rest == ["get-state"] {
            return online ? ok("device\n") : CommandRunner.Result(exitCode: 1, stdout: "", stderr: "offline")
        }
        guard online else { return CommandRunner.Result(exitCode: 1, stdout: "", stderr: "offline") }
        let ledgerMark = DeviceProxyLedger.entries(serial: serial, in: ledger).isEmpty ? "no" : "yes"
        switch rest.first {
        case "reverse" where rest.count == 3 && rest[1] == "--remove":
            if let latch = reverseRemoveLatch { await latch.wait() }
            record("reverse-remove ledger=\(ledgerMark)")
            return ok()
        case "reverse":
            if failReverse { return CommandRunner.Result(exitCode: 1, stdout: "", stderr: "error: closed") }
            record("reverse-add ledger=\(ledgerMark)")
            return ok()
        case "shell":
            return shell(Array(rest.dropFirst()))
        default:
            return ok()
        }
    }

    private func shell(_ command: [String]) -> CommandRunner.Result {
        switch command.prefix(4) {
        case ["settings", "get", "global", "http_proxy"]:
            record("read")
            return ok((proxy ?? "null") + "\n")
        case ["settings", "put", "global", "http_proxy"]:
            let value = command.count > 4 ? command[4] : ""
            if value == ":0" {
                record("clear")
            } else if value.hasPrefix("127.0.0.1:") {
                record("arm")
            } else {
                record("restore \(value)")
            }
            if !ignoresWrites { proxy = value == ":0" ? nil : value }
            return ok()
        default:
            // settings delete, svc wifi: no state the tests read.
            return ok()
        }
    }
}

@MainActor
private final class RecordingSink: CaptureSink {
    var statuses: [String?] = []
    var ports: [Int] = []
    var needsSetup = 0
    func capture(didReceive transaction: NetworkTransaction) {}
    func capture(didChangeStatus status: String?) { statuses.append(status) }
    func capture(didBindPort port: Int) { ports.append(port) }
    func captureNeedsSetup() { needsSetup += 1 }
}

/// A one-shot gate an async call can wait on.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}
