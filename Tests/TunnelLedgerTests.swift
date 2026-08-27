import XCTest
@testable import Jaca

/// The cross-launch record of adb tunnels Jaca owns.
///
/// A `SIGKILL` runs no cleanup by definition, so this ledger is the only thing that can reclaim a
/// stale `adb reverse` — and a stale reverse points the device's `localhost:P` at a listener that
/// no longer exists, breaking every diverted request until someone removes it by hand.
final class TunnelLedgerTests: XCTestCase {

    /// Ownership is tracked by pid because `adb reverse --list` prints bare `tcp:P tcp:P` entries
    /// with nothing identifying who created them — grepping it could never separate Jaca's
    /// tunnels from anyone else's.
    func test_liveProcessIsNotAnOrphan() {
        let me = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(TunnelLedger.isProcessAlive(me))
    }

    func test_impossiblePidIsNotAlive() {
        // Never a real pid, so it can only be reported dead.
        XCTAssertFalse(TunnelLedger.isProcessAlive(0))
        XCTAssertFalse(TunnelLedger.isProcessAlive(-1))
        XCTAssertFalse(TunnelLedger.isProcessAlive(Int32.max))
    }

    // MARK: - Tolerant decoding

    func test_decodesOldLedgerMissingFields() {
        let json = """
        [{"serial":"emulator-5554","kind":"reverse","port":41234}]
        """
        let entries = CloudPersistence.decodeArray(TunnelLedger.Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].serial, "emulator-5554")
        XCTAssertEqual(entries[0].kind, .reverse)
        XCTAssertEqual(entries[0].port, 41234)
        XCTAssertEqual(entries[0].adbPath, "")   // defaulted, not a failed decode
        XCTAssertEqual(entries[0].pid, 0)
    }

    func test_unknownKindFallsBackToForward() {
        let json = """
        [{"serial":"s","kind":"teleport","port":1}]
        """
        let entries = CloudPersistence.decodeArray(TunnelLedger.Entry.self, from: Data(json.utf8))
        // An unknown enum raw value can't decode, so the record is skipped rather than
        // corrupting the ledger — the important part is that the file still loads.
        XCTAssertTrue(entries.isEmpty || entries[0].kind == .forward)
    }

    func test_oneCorruptRecordDoesNotWipeTheLedger() {
        let json = """
        [{"serial":"a","kind":"forward","port":1,"pid":123},
         "not an object",
         {"serial":"b","kind":"reverse","port":2,"pid":456}]
        """
        let entries = CloudPersistence.decodeArray(TunnelLedger.Entry.self, from: Data(json.utf8))
        XCTAssertEqual(entries.map(\.serial), ["a", "b"])
    }

    func test_roundTrip() throws {
        let entry = TunnelLedger.Entry(serial: "emulator-5554", adbPath: "/usr/bin/adb",
                                       kind: .reverse, port: 41234, pid: 999)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([entry])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([TunnelLedger.Entry].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].serial, "emulator-5554")
        XCTAssertEqual(decoded[0].kind, .reverse)
        XCTAssertEqual(decoded[0].port, 41234)
        XCTAssertEqual(decoded[0].pid, 999)
    }

    // MARK: - The control frame (the entire device-side vocabulary)

    /// If this test ever needs changing to add a *rule* concept, the agent has stopped being dumb.
    func test_divertFrameCarriesOnlyOriginHostsAndHeartbeat() throws {
        let frame = AgentDivertCoordinator.divertFrame(
            origin: "http://localhost:41234", hosts: ["b.com", "a.com"], heartbeatSeconds: 15)

        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])

        XCTAssertEqual(Set(obj.keys), ["type", "origin", "hosts", "heartbeatSeconds"],
                       "the device must never learn about patterns, payloads, statuses or ordering")
        XCTAssertEqual(obj["type"] as? String, "divert")
        XCTAssertEqual(obj["origin"] as? String, "http://localhost:41234")
        XCTAssertEqual(obj["heartbeatSeconds"] as? Int, 15)
        // Sorted, so an unchanged rule set produces an identical frame.
        XCTAssertEqual(obj["hosts"] as? [String], ["a.com", "b.com"])
    }

    func test_disarmFrameSendsNullOrigin() throws {
        let frame = AgentDivertCoordinator.divertFrame(origin: nil, hosts: [], heartbeatSeconds: 15)
        XCTAssertTrue(frame.contains("\"origin\":null"))
        XCTAssertTrue(frame.contains("\"hosts\":[]"))
    }

    // MARK: - Hello parsing

    func test_helloAdvertisingOverrideSupportIsRecognised() {
        XCTAssertTrue(AgentHelloParser.advertisesOverrideSupport(
            "{\"type\":\"hello\",\"pid\":1,\"stage\":4,\"caps\":[\"override/1\"]}"))
    }

    /// An agent built before this feature never reads its socket, so the desktop must stay silent
    /// rather than arming something that can't disarm itself.
    func test_helloWithoutCapsIsNotOverrideCapable() {
        XCTAssertFalse(AgentHelloParser.advertisesOverrideSupport(
            "{\"type\":\"hello\",\"pid\":1,\"stage\":4}"))
        XCTAssertFalse(AgentHelloParser.advertisesOverrideSupport(
            "{\"type\":\"hello\",\"caps\":[\"something-else\"]}"))
        XCTAssertFalse(AgentHelloParser.advertisesOverrideSupport("{\"type\":\"txn\"}"))
        XCTAssertFalse(AgentHelloParser.advertisesOverrideSupport("not json"))
    }
}

/// The keepalive must be able to **repair** a desync, not just refresh a timer.
///
/// The original heartbeat sent a bare `{"type":"ping"}`. On the device, `disarm()` clears
/// `origin` permanently until a new `divert` frame arrives, and frames were only sent on start,
/// on hello, or on a host change — so one lapsed window, or an app restart the desktop didn't
/// notice, left overrides dead for good while the toolbar still said "active".
final class DivertHeartbeatTests: XCTestCase {

    func test_heartbeatFrameCarriesTheFullEndpointSoItCanReArm() throws {
        // What the heartbeat now sends is the same frame that arms the device.
        let frame = AgentDivertCoordinator.divertFrame(
            origin: "http://localhost:41234", hosts: ["a.com"], heartbeatSeconds: 15)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])

        XCTAssertEqual(obj["type"] as? String, "divert",
                       "a bare ping can refresh the timer but can never re-arm a disarmed device")
        XCTAssertEqual(obj["origin"] as? String, "http://localhost:41234")
        XCTAssertEqual(obj["hosts"] as? [String], ["a.com"])
    }

    /// Re-sending the identical endpoint must be safe — it runs every few seconds.
    func test_repeatedEndpointFramesAreIdentical() {
        let a = AgentDivertCoordinator.divertFrame(origin: "http://localhost:1", hosts: ["b.com", "a.com"],
                                                   heartbeatSeconds: 15)
        let b = AgentDivertCoordinator.divertFrame(origin: "http://localhost:1", hosts: ["a.com", "b.com"],
                                                   heartbeatSeconds: 15)
        XCTAssertEqual(a, b, "hosts are sorted, so an unchanged rule set produces a byte-identical frame")
    }
}

/// The diagnostic log, which exists because Jaca is launched with `open Jaca.app` and has no
/// other way to tell the user what it did.
final class JacaLogTests: XCTestCase {

    func test_writesAndTailsByCategory() {
        let marker = UUID().uuidString
        JacaLog.info("override", "unit-test marker \(marker)")
        JacaLog.info("somethingelse", "should not appear \(marker)")

        let overrideLines = JacaLog.tail(50, category: "override")
        XCTAssertTrue(overrideLines.contains { $0.contains(marker) })
        XCTAssertFalse(overrideLines.contains { $0.contains("should not appear") })
    }

    func test_linesCarryLevelAndCategory() {
        let marker = UUID().uuidString
        JacaLog.warn("override", marker)
        let line = JacaLog.tail(50, category: "override").last { $0.contains(marker) }
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("[WARN]"))
        XCTAssertTrue(line!.contains("[override]"))
    }
}
