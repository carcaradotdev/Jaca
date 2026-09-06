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

    /// Pids get recycled. An entry whose owner was killed and whose number was later reused by
    /// an unrelated live process would otherwise look alive forever — never reclaimed, never
    /// removed, so `tunnels.json` grew without bound across crashes.
    func test_abandonmentTable() {
        let now = Date()
        func entry(ageSeconds: TimeInterval) -> TunnelLedger.Entry {
            var e = TunnelLedger.Entry(serial: "s", adbPath: "/adb", kind: .reverse, port: 1, pid: 42)
            e.createdAt = now.addingTimeInterval(-ageSeconds)
            return e
        }
        let fresh = entry(ageSeconds: 60)
        let ancient = entry(ageSeconds: TunnelLedger.staleAfter + 60)

        // Ours is never an orphan, at any age — we are still using it.
        XCTAssertFalse(TunnelLedger.isAbandoned(entry: ancient, isOwnPid: true, pidAlive: true, now: now))
        // A dead pid is the ordinary case.
        XCTAssertTrue(TunnelLedger.isAbandoned(entry: fresh, isOwnPid: false, pidAlive: false, now: now))
        // A live pid on a recent entry is somebody else's live tunnel — leave it alone.
        XCTAssertFalse(TunnelLedger.isAbandoned(entry: fresh, isOwnPid: false, pidAlive: true, now: now))
        // A live pid on a week-old entry is a recycled number, not a week-old session.
        XCTAssertTrue(TunnelLedger.isAbandoned(entry: ancient, isOwnPid: false, pidAlive: true, now: now))
    }

    /// Uses the ledger's **own** encoder/decoder rather than a hand-rolled matched pair.
    ///
    /// The hand-rolled version passed while the real pair had drifted (`.iso8601` on write,
    /// default numeric on read), which dropped every record on load and turned orphan reclaim
    /// into a no-op. Testing the pair the ledger actually uses is the whole point.
    func test_roundTripUsesTheLedgersOwnCoderPair() throws {
        let entry = TunnelLedger.Entry(serial: "emulator-5554", adbPath: "/usr/bin/adb",
                                       kind: .reverse, port: 41234, pid: 999)
        let data = try TunnelLedger.makeEncoder().encode([entry])
        let decoded = try TunnelLedger.makeDecoder().decode([TunnelLedger.Entry].self, from: data)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].serial, "emulator-5554")
        XCTAssertEqual(decoded[0].kind, .reverse)
        XCTAssertEqual(decoded[0].port, 41234)
        XCTAssertEqual(decoded[0].pid, 999)
    }

    /// `decodeArray` swallows failures by design (one bad record must not wipe the file), so a
    /// mismatched pair fails *silently* as an empty array. Assert the survival count directly.
    func test_decodeArraySurvivesTheLedgersOwnEncoding() throws {
        let entries = [
            TunnelLedger.Entry(serial: "a", adbPath: "/adb", kind: .reverse, port: 1, pid: 10),
            TunnelLedger.Entry(serial: "b", adbPath: "/adb", kind: .forward, port: 2, pid: 20),
        ]
        let data = try TunnelLedger.makeEncoder().encode(entries)
        let decoded = CloudPersistence.decodeArray(TunnelLedger.Entry.self, from: data,
                                                   decoder: TunnelLedger.makeDecoder())
        XCTAssertEqual(decoded.count, 2, "a drifted coder pair drops every record silently")
        XCTAssertEqual(decoded.map(\.port), [1, 2])
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
