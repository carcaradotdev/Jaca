import XCTest
@testable import Jaca

/// The cross-launch record of device proxies Jaca set. A `SIGKILL` leaves the device pointed at
/// a dead `127.0.0.1:P`, so it shows as connected but has no internet. This ledger is what lets
/// the next start put it back.
final class DeviceProxyLedgerTests: XCTestCase {
    private var dir: URL!
    private var file: JSONLedgerFile<DeviceProxyLedger.Entry>!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceProxyLedgerTests-\(UUID().uuidString)")
        file = JSONLedgerFile(fileURL: dir.appendingPathComponent("device-proxies.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func entry(serial: String = "emulator-5554", port: Int = 41234, previous: String? = nil,
                       pid: Int32 = 4242, age: TimeInterval = 60, now: Date = Date()) -> DeviceProxyLedger.Entry {
        DeviceProxyLedger.Entry(serial: serial, adbPath: "/adb", port: port,
                                value: DeviceProxyPlan.loopbackValue(port: port), previous: previous,
                                pid: pid, createdAt: now.addingTimeInterval(-age))
    }

    // MARK: - Tolerant decoding

    func test_oldSchemaWithoutPreviousLoadsWithPreviousNil() {
        let json = """
        [{"serial":"emulator-5554","adbPath":"/adb","port":41234,"value":"127.0.0.1:41234",
          "pid":123,"createdAt":"2026-11-01T10:00:00Z"}]
        """
        let entries = CloudPersistence.decodeArray(DeviceProxyLedger.Entry.self, from: Data(json.utf8),
                                                   decoder: JSONLedgerFile<DeviceProxyLedger.Entry>.makeDecoder())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].serial, "emulator-5554")
        XCTAssertEqual(entries[0].port, 41234)
        XCTAssertEqual(entries[0].value, "127.0.0.1:41234")
        XCTAssertNil(entries[0].previous)
        XCTAssertEqual(entries[0].pid, 123)
        XCTAssertFalse(entries[0].released, "an entry from before `released` existed is held")
    }

    func test_releasedRoundTripsThroughTheFile() {
        let file = JSONLedgerFile<DeviceProxyLedger.Entry>(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("jaca-ledger-\(UUID().uuidString)/device-proxies.json"))
        defer { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
        DeviceProxyLedger.add(serial: "s", adbPath: "/adb", port: 9000, previous: nil, in: file)
        DeviceProxyLedger.markReleased(serial: "s", port: 9000, in: file)
        XCTAssertEqual(DeviceProxyLedger.load(in: file).first?.released, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.fileURL.path + ".lock"),
                      "writes take the cross-process file lock")
    }

    func test_releasedEntryIsAbandonedWhileItsOwnerRuns() {
        var released = DeviceProxyLedger.Entry(serial: "s", adbPath: "/adb", port: 1, value: "127.0.0.1:1",
                                               previous: nil, pid: 10, createdAt: Date())
        released.released = true
        XCTAssertTrue(DeviceProxyLedger.isAbandoned(entry: released, pidAlive: true, isOwnPid: false, now: Date()))
        XCTAssertTrue(DeviceProxyLedger.isAbandoned(entry: released, pidAlive: true, isOwnPid: true, now: Date()))
    }

    /// A recycled pid that now runs another program does not keep an entry alive.
    func test_isJacaExecutable() {
        XCTAssertTrue(DeviceProxyLedger.isJacaExecutable("/Applications/Jaca.app/Contents/MacOS/Jaca"))
        XCTAssertTrue(DeviceProxyLedger.isJacaExecutable("/Applications/Jaca.app/Contents/MacOS/jacad"))
        XCTAssertFalse(DeviceProxyLedger.isJacaExecutable("/usr/libexec/syspolicyd"))
        XCTAssertFalse(DeviceProxyLedger.liveOwnerCheck(Int32.max), "a pid that doesn't run is dead")
    }

    func test_restoreTargetClearsAnyJacaLoopbackValue() {
        XCTAssertNil(DeviceProxyLedger.restoreTarget(previous: "127.0.0.1:41234", otherValues: []),
                     "an overlapping capture's value, even with its entry gone, is cleared")
        XCTAssertEqual(DeviceProxyLedger.restoreTarget(previous: "127.0.0.1.example:80", otherValues: []),
                       "127.0.0.1.example:80")
        XCTAssertFalse(DeviceProxyPlan.isLoopbackValue("127.0.0.1:abc"))
    }

    // MARK: - Quit-time revert

    func test_quitRevert_restoresAndChecks() {
        var device: AndroidProxyReading = .value("127.0.0.1:9000")
        var applied: [[String]] = []
        let ok = ProxyCleanup.quitRevert(value: "127.0.0.1:9000", previous: "10.0.0.5:8888", otherValues: [],
                                         serial: "s", read: { device },
                                         apply: { applied.append($0); device = .value("10.0.0.5:8888"); return true })
        XCTAssertTrue(ok)
        XCTAssertEqual(applied, [DeviceProxyPlan.restorePrevious(serial: "s", previous: "10.0.0.5:8888")])
    }

    func test_quitRevert_leavesAnotherValueAlone() {
        var applied = 0
        XCTAssertTrue(ProxyCleanup.quitRevert(value: "127.0.0.1:9000", previous: nil, otherValues: [], serial: "s",
                                              read: { .value("proxy.corp:3128") }, apply: { _ in applied += 1; return true }))
        XCTAssertEqual(applied, 0)
    }

    /// adb failed or the phone is unplugged: the ledger keeps the entry.
    func test_quitRevert_failureKeepsTheEntry() {
        XCTAssertFalse(ProxyCleanup.quitRevert(value: "127.0.0.1:9000", previous: nil, otherValues: [], serial: "s",
                                               read: { .unreachable }, apply: { _ in true }))
        XCTAssertFalse(ProxyCleanup.quitRevert(value: "127.0.0.1:9000", previous: nil, otherValues: [], serial: "s",
                                               read: { .value("127.0.0.1:9000") }, apply: { _ in false }))
    }

    func test_missingFieldsDefaultInsteadOfFailing() {
        let json = """
        [{"serial":"s"}]
        """
        let entries = CloudPersistence.decodeArray(DeviceProxyLedger.Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].adbPath, "")
        XCTAssertEqual(entries[0].port, 0)
        XCTAssertEqual(entries[0].value, "")
        XCTAssertEqual(entries[0].pid, 0)
    }

    func test_oneCorruptRecordDoesNotWipeTheLedger() {
        let json = """
        [{"serial":"a","port":1,"value":"127.0.0.1:1","pid":10},
         "not an object",
         {"serial":"b","port":2,"value":"127.0.0.1:2","pid":20}]
        """
        let entries = CloudPersistence.decodeArray(DeviceProxyLedger.Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entries.map(\.serial), ["a", "b"])
    }

    func test_roundTripThroughTheFileKeepsEveryField() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let e = entry(previous: "10.0.0.5:8888", now: now)
        DeviceProxyLedger.add(e, in: file)
        XCTAssertEqual(DeviceProxyLedger.load(in: file), [entry(previous: "10.0.0.5:8888", now: now)])
    }

    // MARK: - Records

    func test_addReplacesTheSameSerialAndPort() {
        DeviceProxyLedger.add(entry(previous: nil), in: file)
        DeviceProxyLedger.add(entry(previous: "1.2.3.4:80"), in: file)
        DeviceProxyLedger.add(entry(port: 5000), in: file)
        DeviceProxyLedger.add(entry(serial: "other"), in: file)

        let mine = DeviceProxyLedger.entries(serial: "emulator-5554", in: file)
        XCTAssertEqual(mine.map(\.port).sorted(), [5000, 41234])
        XCTAssertEqual(DeviceProxyLedger.entry(serial: "emulator-5554", port: 41234, in: file)?.previous,
                       "1.2.3.4:80")

        DeviceProxyLedger.remove(serial: "emulator-5554", port: 41234, in: file)
        XCTAssertEqual(DeviceProxyLedger.entries(serial: "emulator-5554", in: file).map(\.port), [5000])
        XCTAssertEqual(DeviceProxyLedger.entries(serial: "other", in: file).count, 1)
    }

    func test_convenienceAddWritesTheLoopbackValueAndOwnPid() {
        DeviceProxyLedger.add(serial: "s", adbPath: "/adb", port: 9000, previous: nil, in: file)
        let e = DeviceProxyLedger.entries(serial: "s", in: file).first
        XCTAssertEqual(e?.value, "127.0.0.1:9000")
        XCTAssertEqual(e?.pid, ProcessInfo.processInfo.processIdentifier)
    }

    func test_missingFileReadsAsEmpty() {
        XCTAssertEqual(DeviceProxyLedger.load(in: file), [])
    }

    // MARK: - shouldRevert

    func test_shouldRevertTable() {
        let now = Date()
        let fresh = entry(age: 60, now: now)
        let stale = entry(age: DeviceProxyLedger.staleAfter + 60, now: now)
        let ours = fresh.value

        // Our own entry: we still use it, at any age.
        XCTAssertFalse(DeviceProxyLedger.shouldRevert(entry: stale, current: ours, pidAlive: true,
                                                      isOwnPid: true, now: now))
        // A dead owner and the device still reads our value: revert.
        XCTAssertTrue(DeviceProxyLedger.shouldRevert(entry: fresh, current: ours, pidAlive: false,
                                                     isOwnPid: false, now: now))
        // A live owner on a recent entry is another process's capture: leave it.
        XCTAssertFalse(DeviceProxyLedger.shouldRevert(entry: fresh, current: ours, pidAlive: true,
                                                      isOwnPid: false, now: now))
        // A live pid on a week-old entry is a recycled number: revert.
        XCTAssertTrue(DeviceProxyLedger.shouldRevert(entry: stale, current: ours, pidAlive: true,
                                                     isOwnPid: false, now: now))
        // The user changed the proxy after Jaca: never overwrite it.
        XCTAssertFalse(DeviceProxyLedger.shouldRevert(entry: fresh, current: "10.0.0.5:8888",
                                                      pidAlive: false, isOwnPid: false, now: now))
        // The proxy is already gone.
        XCTAssertFalse(DeviceProxyLedger.shouldRevert(entry: fresh, current: nil, pidAlive: false,
                                                      isOwnPid: false, now: now))
    }

    func test_reconcileActionTable() {
        let now = Date()
        let e = entry(previous: "10.0.0.5:8888", now: now)

        XCTAssertEqual(DeviceProxyLedger.reconcileAction(entry: e, reading: .unreachable, pidAlive: false,
                                                         isOwnPid: false, now: now, otherValues: []), .keep)
        XCTAssertEqual(DeviceProxyLedger.reconcileAction(entry: e, reading: .value(e.value), pidAlive: true,
                                                         isOwnPid: false, now: now, otherValues: []), .keep)
        XCTAssertEqual(DeviceProxyLedger.reconcileAction(entry: e, reading: .value(e.value), pidAlive: false,
                                                         isOwnPid: false, now: now, otherValues: []),
                       .revert(restore: "10.0.0.5:8888"))
        XCTAssertEqual(DeviceProxyLedger.reconcileAction(entry: e, reading: .noProxy, pidAlive: false,
                                                         isOwnPid: false, now: now, otherValues: []), .forget)
        XCTAssertEqual(DeviceProxyLedger.reconcileAction(entry: e, reading: .value("1.1.1.1:1"), pidAlive: false,
                                                         isOwnPid: false, now: now, otherValues: []), .forget)
    }

    func test_restoreTargetClearsWhenPreviousIsAnotherStrandedJacaProxy() {
        XCTAssertNil(DeviceProxyLedger.restoreTarget(previous: nil, otherValues: []))
        XCTAssertNil(DeviceProxyLedger.restoreTarget(previous: ":0", otherValues: []))
        XCTAssertNil(DeviceProxyLedger.restoreTarget(previous: "127.0.0.1:5000",
                                                     otherValues: ["127.0.0.1:5000"]))
        XCTAssertEqual(DeviceProxyLedger.restoreTarget(previous: "10.0.0.5:8888", otherValues: []),
                       "10.0.0.5:8888")
    }

    func test_readingParse() {
        XCTAssertEqual(AndroidProxyReading.parse(exitCode: nil, stdout: ""), .unreachable)
        XCTAssertEqual(AndroidProxyReading.parse(exitCode: 1, stdout: "error: device offline"), .unreachable)
        XCTAssertEqual(AndroidProxyReading.parse(exitCode: 0, stdout: ":0\n"), .noProxy)
        XCTAssertEqual(AndroidProxyReading.parse(exitCode: 0, stdout: "null\n"), .noProxy)
        XCTAssertEqual(AndroidProxyReading.parse(exitCode: 0, stdout: ""), .noProxy)
        XCTAssertEqual(AndroidProxyReading.parse(exitCode: 0, stdout: "127.0.0.1:41234\n"),
                       .value("127.0.0.1:41234"))
    }

    // MARK: - reconcileOrphans

    /// A fake device: `read` returns the current value, `set`/`clear` change it and log the call.
    private final class FakeDevices: @unchecked Sendable {
        private let lock = NSLock()
        private var proxies: [String: AndroidProxyReading]
        private(set) var calls: [String] = []
        var stickToValue = false

        init(_ proxies: [String: AndroidProxyReading]) { self.proxies = proxies }

        var commands: AndroidProxyCommands {
            AndroidProxyCommands(
                read: { _, serial in self.locked { self.proxies[serial] ?? .unreachable } },
                set: { _, serial, value in
                    self.locked {
                        self.calls.append("set \(serial) \(value)")
                        if !self.stickToValue { self.proxies[serial] = .value(value) }
                    }
                },
                clear: { _, serial in
                    self.locked {
                        self.calls.append("clear \(serial)")
                        if !self.stickToValue { self.proxies[serial] = AndroidProxyReading.noProxy }
                    }
                })
        }

        func reading(_ serial: String) -> AndroidProxyReading? { locked { proxies[serial] } }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }
    }

    private func reconcile(_ devices: FakeDevices, serial: String? = nil,
                           alive: Set<Int32> = []) async -> [String] {
        await DeviceProxyLedger.reconcileOrphans(
            adbPath: "/adb", serial: serial, in: file, commands: devices.commands,
            pidAlive: { alive.contains($0) }, ownPid: 1, isExecutable: { _ in true })
    }

    func test_reconcileClearsADeadOwnersProxyAndDropsTheEntry() async {
        let e = entry(serial: "a")
        DeviceProxyLedger.add(e, in: file)
        let devices = FakeDevices(["a": .value(e.value)])

        let reverted = await reconcile(devices)

        XCTAssertEqual(reverted, ["a"])
        XCTAssertEqual(devices.calls, ["clear a"])
        XCTAssertEqual(DeviceProxyLedger.load(in: file), [])
    }

    func test_reconcileRestoresThePreviousProxy() async {
        let e = entry(serial: "a", previous: "10.0.0.5:8888")
        DeviceProxyLedger.add(e, in: file)
        let devices = FakeDevices(["a": .value(e.value)])

        _ = await reconcile(devices)

        XCTAssertEqual(devices.calls, ["set a 10.0.0.5:8888"])
        XCTAssertEqual(devices.reading("a"), .value("10.0.0.5:8888"))
    }

    func test_reconcileKeepsAnOfflineDevicesEntry() async {
        DeviceProxyLedger.add(entry(serial: "a"), in: file)
        let devices = FakeDevices(["a": .unreachable])

        let reverted = await reconcile(devices)

        XCTAssertEqual(reverted, [])
        XCTAssertEqual(devices.calls, [])
        XCTAssertEqual(DeviceProxyLedger.load(in: file).count, 1)
    }

    func test_reconcileLeavesALiveOwnerAlone() async {
        DeviceProxyLedger.add(entry(serial: "a", pid: 77), in: file)
        let devices = FakeDevices(["a": .value("127.0.0.1:41234")])

        _ = await reconcile(devices, alive: [77])

        XCTAssertEqual(devices.calls, [])
        XCTAssertEqual(DeviceProxyLedger.load(in: file).count, 1)
    }

    func test_reconcileNeverOverwritesAProxyTheUserChanged() async {
        DeviceProxyLedger.add(entry(serial: "a"), in: file)
        let devices = FakeDevices(["a": .value("10.0.0.5:8888")])

        _ = await reconcile(devices)

        XCTAssertEqual(devices.calls, [])
        XCTAssertEqual(devices.reading("a"), .value("10.0.0.5:8888"))
        XCTAssertEqual(DeviceProxyLedger.load(in: file), [], "the stale entry is dropped")
    }

    func test_reconcileKeepsTheEntryWhenTheRevertDidNotTakeEffect() async {
        let e = entry(serial: "a")
        DeviceProxyLedger.add(e, in: file)
        let devices = FakeDevices(["a": .value(e.value)])
        devices.stickToValue = true

        let reverted = await reconcile(devices)

        XCTAssertEqual(reverted, [])
        XCTAssertEqual(DeviceProxyLedger.load(in: file).count, 1)
    }

    func test_reconcileForOneSerialSkipsTheOthers() async {
        let a = entry(serial: "a")
        let b = entry(serial: "b")
        DeviceProxyLedger.add(a, in: file)
        DeviceProxyLedger.add(b, in: file)
        let devices = FakeDevices(["a": .value(a.value), "b": .value(b.value)])

        _ = await reconcile(devices, serial: "b")

        XCTAssertEqual(devices.calls, ["clear b"])
        XCTAssertEqual(DeviceProxyLedger.load(in: file).map(\.serial), ["a"])
    }

    func test_usableAdbPathFallsBack() {
        XCTAssertEqual(DeviceProxyLedger.usableAdbPath(entry: "/old/adb", fallback: "/new/adb",
                                                       isExecutable: { $0 == "/old/adb" }), "/old/adb")
        XCTAssertEqual(DeviceProxyLedger.usableAdbPath(entry: "/gone/adb", fallback: "/new/adb",
                                                       isExecutable: { $0 == "/new/adb" }), "/new/adb")
        XCTAssertNil(DeviceProxyLedger.usableAdbPath(entry: "", fallback: nil, isExecutable: { _ in true }))
    }
}

/// The exact adb argument lists for the device proxy. A wrong list fails quietly on the device,
/// so each one is pinned here.
final class DeviceProxyPlanTests: XCTestCase {
    func test_armAndReverse() {
        XCTAssertEqual(DeviceProxyPlan.loopbackValue(port: 41234), "127.0.0.1:41234")
        XCTAssertEqual(DeviceProxyPlan.reverseAdd(serial: "s", port: 41234),
                       ["-s", "s", "reverse", "tcp:41234", "tcp:41234"])
        XCTAssertEqual(DeviceProxyPlan.reverseRemove(serial: "s", port: 41234),
                       ["-s", "s", "reverse", "--remove", "tcp:41234"])
        XCTAssertEqual(DeviceProxyPlan.arm(serial: "s", port: 41234),
                       ["-s", "s", "shell", "settings", "put", "global", "http_proxy", "127.0.0.1:41234"])
        XCTAssertEqual(DeviceProxyPlan.readProxy(serial: "s"),
                       ["-s", "s", "shell", "settings", "get", "global", "http_proxy"])
    }

    func test_restorePrevious() {
        XCTAssertEqual(DeviceProxyPlan.restorePrevious(serial: "s", previous: "10.0.0.5:8888"),
                       ["-s", "s", "shell", "settings", "put", "global", "http_proxy", "10.0.0.5:8888"])
        XCTAssertEqual(DeviceProxyPlan.revert(serial: "s", previous: "10.0.0.5:8888"),
                       [["-s", "s", "shell", "settings", "put", "global", "http_proxy", "10.0.0.5:8888"]])
    }

    func test_clearAndRevertWithoutPrevious() {
        let clear: [[String]] = [
            ["-s", "s", "shell", "settings", "put", "global", "http_proxy", ":0"],
            ["-s", "s", "shell", "settings", "delete", "global", "global_http_proxy_host"],
            ["-s", "s", "shell", "settings", "delete", "global", "global_http_proxy_port"],
            ["-s", "s", "shell", "settings", "delete", "global", "global_http_proxy_exclusion_list"],
        ]
        XCTAssertEqual(DeviceProxyPlan.clear(serial: "s"), clear)
        XCTAssertEqual(DeviceProxyPlan.revert(serial: "s", previous: nil), clear)
        XCTAssertEqual(DeviceProxyPlan.revert(serial: "s", previous: ":0"), clear)
        XCTAssertEqual(DeviceProxyPlan.revert(serial: "s", previous: "null"), clear)
        XCTAssertEqual(DeviceProxyPlan.revert(serial: "s", previous: ""), clear)
    }
}
