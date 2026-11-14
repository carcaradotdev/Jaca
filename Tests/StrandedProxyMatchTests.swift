import XCTest
@testable import Jaca

/// The sidebar "Revert" banner shows only for a device proxy that Jaca left behind.
final class StrandedProxyMatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(port: Int, pid: Int32, age: TimeInterval = 60) -> DeviceProxyLedger.Entry {
        DeviceProxyLedger.Entry(serial: "R58M", adbPath: "/adb", port: port,
                                value: DeviceProxyPlan.loopbackValue(port: port), previous: nil,
                                pid: pid, createdAt: now.addingTimeInterval(-age))
    }

    // MARK: - isOurs

    func test_theLegacyLANIPMatches() {
        XCTAssertTrue(StrandedProxyMatch.isOurs(current: "192.168.1.20:8888", hostAddress: "192.168.1.20",
                                                ledgerValues: []))
        XCTAssertTrue(StrandedProxyMatch.isOurs(current: "10.0.2.2:9090\n", hostAddress: "10.0.2.2",
                                                ledgerValues: []))
    }

    func test_aLedgerValueMatches() {
        XCTAssertTrue(StrandedProxyMatch.isOurs(current: "127.0.0.1:41234", hostAddress: "192.168.1.20",
                                                ledgerValues: ["127.0.0.1:41234"]))
    }

    func test_aForeignValueDoesNotMatch() {
        XCTAssertFalse(StrandedProxyMatch.isOurs(current: "proxy.corp.example:3128", hostAddress: "192.168.1.20",
                                                 ledgerValues: ["127.0.0.1:41234"]))
        // Charles or Proxyman over adb reverse: loopback, but not in the ledger.
        XCTAssertFalse(StrandedProxyMatch.isOurs(current: "127.0.0.1:8888", hostAddress: "192.168.1.20",
                                                 ledgerValues: ["127.0.0.1:41234"]))
    }

    func test_aLoopbackHostAddressNeverMatchesByHost() {
        // No LAN IP: hostAddress falls back to 127.0.0.1, which every adb reverse proxy uses.
        XCTAssertFalse(StrandedProxyMatch.isOurs(current: "127.0.0.1:8888", hostAddress: "127.0.0.1",
                                                 ledgerValues: []))
    }

    func test_noProxyDoesNotMatch() {
        for value in ["", ":0", "null", "  "] {
            XCTAssertFalse(StrandedProxyMatch.isOurs(current: value, hostAddress: "192.168.1.20",
                                                     ledgerValues: [":0", "null"]), value)
        }
    }

    // MARK: - split

    func test_split_ownArmedPortIsLive_ownUnarmedPortIsStranded() {
        let split = StrandedProxyMatch.split(
            entries: [entry(port: 1000, pid: 10), entry(port: 2000, pid: 10)],
            ownPid: 10, armedPorts: [1000], pidAlive: { _ in true }, now: now)
        XCTAssertEqual(split.live, ["127.0.0.1:1000"])
        XCTAssertEqual(split.stranded, ["127.0.0.1:2000"])
    }

    /// jacad's stop couldn't revert the device. jacad still runs, but no capture holds the value,
    /// so the sidebar must offer Revert.
    func test_split_aReleasedEntryIsStrandedWhileItsOwnerRuns() {
        var released = entry(port: 3000, pid: 20)
        released.released = true
        var ownReleased = entry(port: 4000, pid: 10)
        ownReleased.released = true
        let split = StrandedProxyMatch.split(entries: [released, ownReleased], ownPid: 10, armedPorts: [4000],
                                             pidAlive: { _ in true }, now: now)
        XCTAssertEqual(split.live, [])
        XCTAssertEqual(split.stranded, ["127.0.0.1:3000", "127.0.0.1:4000"])
    }

    func test_split_anotherLiveProcessIsLive_aDeadOneIsStranded() {
        let split = StrandedProxyMatch.split(
            entries: [entry(port: 1000, pid: 20), entry(port: 2000, pid: 30)],
            ownPid: 10, armedPorts: [], pidAlive: { $0 == 20 }, now: now)
        XCTAssertEqual(split.live, ["127.0.0.1:1000"])
        XCTAssertEqual(split.stranded, ["127.0.0.1:2000"])
    }

    func test_split_aStaleEntryOfALiveProcessIsStranded() {
        let split = StrandedProxyMatch.split(
            entries: [entry(port: 1000, pid: 20, age: DeviceProxyLedger.staleAfter + 60)],
            ownPid: 10, armedPorts: [], pidAlive: { _ in true }, now: now)
        XCTAssertEqual(split.live, [])
        XCTAssertEqual(split.stranded, ["127.0.0.1:1000"])
    }
}
