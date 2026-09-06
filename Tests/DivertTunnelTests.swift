import XCTest
@testable import Jaca

/// The tunnel seam is what keeps `Core/Overrides/` free of adb. Two things are worth asserting
/// here and nowhere else: the exact `adb` invocation (a typo in it disables the whole feature with
/// no compile error), and that shared loopback really is free of persistent state — the ledger is
/// the mechanism that reclaims a stranded tunnel, and a transport that has nothing to strand must
/// never write to it.
final class DivertTunnelTests: XCTestCase {

    // MARK: - Shared loopback (iOS Simulator)

    func test_sharedLoopbackNamesTheMacsOwnLoopback() {
        XCTAssertEqual(SharedLoopbackTunnel().origin(forLocalPort: 9), "http://127.0.0.1:9")
    }

    /// Nothing is created, so nothing can outlive a `SIGKILL`, so there is nothing to reconcile.
    func test_sharedLoopbackNeedsNoLedger() {
        XCTAssertFalse(SharedLoopbackTunnel().needsTunnelLedger)
    }

    /// The guarantee behind that flag, checked against the real on-disk ledger rather than the
    /// declaration: opening and closing a shared-loopback tunnel must leave the file byte-identical
    /// (including "still absent"). A stray `register` here would make every Simulator session queue
    /// an `adb reverse --remove` against a serial that doesn't exist.
    func test_sharedLoopbackOpenAndCloseLeaveTheLedgerUntouched() async throws {
        let before = try? Data(contentsOf: TunnelLedger.fileURL)

        let tunnel = SharedLoopbackTunnel()
        try await tunnel.open(localPort: 41234)
        await tunnel.close(localPort: 41234)

        let after = try? Data(contentsOf: TunnelLedger.fileURL)
        XCTAssertEqual(before, after)
    }

    // MARK: - adb reverse (Android)

    /// Same port on both sides on purpose: no stdout to parse, and an OS-allocated local port
    /// can't collide with a forward that already exists.
    func test_openArgumentsMapThePortOneToOne() {
        XCTAssertEqual(AdbReverseTunnel.openArguments(serial: "X", port: 41234),
                       ["-s", "X", "reverse", "tcp:41234", "tcp:41234"])
    }

    func test_removeArgumentsTargetTheSamePort() {
        XCTAssertEqual(AdbReverseTunnel.removeArguments(serial: "X", port: 41234),
                       ["-s", "X", "reverse", "--remove", "tcp:41234"])
    }

    /// The device reaches us over *its* loopback, which `adb reverse` bridges — not the Mac's.
    func test_adbReverseNamesTheDeviceLoopback() {
        let tunnel = AdbReverseTunnel(adbPath: "/nonexistent/adb", serial: "X")
        XCTAssertEqual(tunnel.origin(forLocalPort: 41234), "http://localhost:41234")
    }

    /// A reverse lives in the adb server, so it survives a `SIGKILL` and has to be reclaimable.
    func test_adbReverseNeedsTheLedger() {
        XCTAssertTrue(AdbReverseTunnel(adbPath: "/nonexistent/adb", serial: "X").needsTunnelLedger)
    }
}
