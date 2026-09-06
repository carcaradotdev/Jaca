import XCTest
@testable import Jaca

/// The shared `launchctl list` parser.
///
/// It replaced a copy that lived inside `SimulatorLogSource.resolvePIDs`, so these fixtures are
/// deliberately every shape that copy handled: the `UIKitApplication:` label with its two
/// job-label suffix variants, the bare suffix form, the `-` pid column, and padded output. A
/// regression here is a Logs session that silently filters every line away.
final class SimulatorProcessesTests: XCTestCase {

    private let list = """
    PID\tStatus\tLabel
    -\t0\tcom.apple.CoreSimulator.SimulatorTrampoline
    73826\t0\tUIKitApplication:com.example.App[6a1f][rb-legacy]
    """

    func test_pidComesFromTheUIKitApplicationLabel() {
        XCTAssertEqual(SimulatorProcesses.pid(bundleID: "com.example.App", inLaunchctlList: list), 73826)
        XCTAssertEqual(SimulatorProcesses.pids(bundleID: "com.example.App", inLaunchctlList: list), [73826])
        XCTAssertTrue(SimulatorProcesses.isRunning(bundleID: "com.example.App", inLaunchctlList: list))
    }

    /// launchd knows the job but nothing is running — the shape a just-quit app leaves behind.
    func test_dashPidColumnMeansNotRunning() {
        let output = "-\t0\tUIKitApplication:com.example.App[0x1][1be2]\n"
        XCTAssertNil(SimulatorProcesses.pid(bundleID: "com.example.App", inLaunchctlList: output))
        XCTAssertFalse(SimulatorProcesses.isRunning(bundleID: "com.example.App", inLaunchctlList: output))
    }

    /// The reason the match is an exact comparison and not a prefix test: an app and its extension
    /// share a bundle-id prefix, and the extension's pid would filter the app's log lines away.
    func test_bundleIDDoesNotMatchAnExtensionWithTheSamePrefix() {
        let output = """
        4242\t0\tUIKitApplication:com.example.AppExtension[0x1][1be2]
        """
        XCTAssertNil(SimulatorProcesses.pid(bundleID: "com.example.App", inLaunchctlList: output))
        XCTAssertEqual(SimulatorProcesses.pid(bundleID: "com.example.AppExtension", inLaunchctlList: output), 4242)
    }

    func test_bothJobLabelVariantsParse() {
        let hex = "11\t0\tUIKitApplication:com.example.App[0x1][1be2]"
        let handle = "22\t0\tUIKitApplication:com.example.App[6a1f][rb-legacy]"
        XCTAssertEqual(SimulatorProcesses.pid(bundleID: "com.example.App", inLaunchctlList: hex), 11)
        XCTAssertEqual(SimulatorProcesses.pid(bundleID: "com.example.App", inLaunchctlList: handle), 22)
    }

    /// The bare-suffix shape (no `[…]` at all) was the second branch of the old parser.
    func test_bareSuffixLabelParses() {
        let output = "99\t0\tUIKitApplication:com.example.App"
        XCTAssertEqual(SimulatorProcesses.pid(bundleID: "com.example.App", inLaunchctlList: output), 99)
    }

    func test_crlfAndBlankLinePaddingAreTolerated() {
        let output = "PID\tStatus\tLabel\r\n\r\n73826\t0\tUIKitApplication:com.example.App[6a1f][rb-legacy]\r\n\r\n"
        XCTAssertEqual(SimulatorProcesses.pids(bundleID: "com.example.App", inLaunchctlList: output), [73826])
    }

    func test_emptyOutputOrEmptyBundleIDIsNotRunning() {
        XCTAssertNil(SimulatorProcesses.pid(bundleID: "com.example.App", inLaunchctlList: ""))
        XCTAssertNil(SimulatorProcesses.pid(bundleID: "", inLaunchctlList: list))
        XCTAssertEqual(SimulatorProcesses.pids(bundleID: "", inLaunchctlList: list), [])
        XCTAssertFalse(SimulatorProcesses.isRunning(bundleID: "", inLaunchctlList: list))
    }

    /// Multiple live entries for one app (a relaunch race) — the log filter wants both pids.
    func test_everyMatchingPidIsReturned() {
        let output = """
        11\t0\tUIKitApplication:com.example.App[0x1][1be2]
        22\t0\tUIKitApplication:com.example.App[6a1f][rb-legacy]
        -\t0\tUIKitApplication:com.example.App[0x2][aaaa]
        """
        XCTAssertEqual(SimulatorProcesses.pids(bundleID: "com.example.App", inLaunchctlList: output), [11, 22])
    }
}
