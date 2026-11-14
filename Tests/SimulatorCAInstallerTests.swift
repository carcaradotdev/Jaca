import XCTest
@testable import Jaca

/// `simctl keychain` changes a simulator, so every test runs against a fake `xcrun`.
final class SimulatorCAInstallerTests: XCTestCase {
    private let udid = "83682192-0F63-4379-B374-980D9AFE5FF7"
    private let pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"

    func test_install_runsAddRootCertWithThePEMFile() async throws {
        let xcrun = FakeXcrun()
        xcrun.inspect = { arguments in
            // The PEM file exists while simctl reads it.
            guard let path = arguments.last else { return }
            XCTAssertEqual(try? String(contentsOfFile: path, encoding: .utf8), self.pem)
        }
        let result = await SimulatorCAInstaller(run: xcrun.runner).install(udid: udid, caPEM: pem)
        XCTAssertNoThrow(try result.get())

        let call = try XCTUnwrap(xcrun.calls.first)
        XCTAssertEqual(Array(call.prefix(4)), ["simctl", "keychain", udid, "add-root-cert"])
        XCTAssertTrue(call[4].hasSuffix(".pem"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: call[4]), "the temporary file is removed")
    }

    func test_install_shutdownSimulatorGivesAReadableMessage() async {
        let xcrun = FakeXcrun()
        xcrun.results = [CommandRunner.Result(exitCode: 149, stdout: "", stderr: """
            An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):
            Unable to lookup in current state: Shutdown
            """)]
        let result = await SimulatorCAInstaller(run: xcrun.runner).install(udid: udid, caPEM: pem)
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.message, "Boot the simulator, then try again.")
    }

    func test_errorText_keepsTheReasonAndDropsTheHeader() {
        let result = CommandRunner.Result(exitCode: 1, stdout: "", stderr: """
            An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=2):
            The certificate could not be read.
            Underlying error (domain=NSCocoaErrorDomain, code=260):
            """)
        XCTAssertEqual(SimctlErrorText.message(from: result), "The certificate could not be read.")
    }

    func test_errorText_headerOnlyAndEmptyOutputAreNeverBlank() {
        let header = CommandRunner.Result(exitCode: 1, stdout: "",
                                          stderr: "An error was encountered processing the command (domain=X, code=1):\n")
        XCTAssertFalse(SimctlErrorText.message(from: header).isEmpty)
        let empty = CommandRunner.Result(exitCode: 3, stdout: "", stderr: "")
        XCTAssertEqual(SimctlErrorText.message(from: empty), "simctl exited with code 3.")
    }

    func test_reboot_runsShutdownThenBoot() async {
        let xcrun = FakeXcrun()
        let result = await SimulatorCAInstaller(run: xcrun.runner).reboot(udid: udid)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(xcrun.calls, [["simctl", "shutdown", udid], ["simctl", "boot", udid]])
    }

    func test_reboot_alreadyShutDownStillBoots() async {
        let xcrun = FakeXcrun()
        xcrun.results = [
            CommandRunner.Result(exitCode: 149, stdout: "",
                                 stderr: "Unable to shutdown device in current state: Shutdown\n"),
            CommandRunner.Result(exitCode: 0, stdout: "", stderr: ""),
        ]
        let result = await SimulatorCAInstaller(run: xcrun.runner).reboot(udid: udid)
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(xcrun.calls.count, 2)
    }

    func test_reboot_bootFailureIsReported() async {
        let xcrun = FakeXcrun()
        xcrun.results = [
            CommandRunner.Result(exitCode: 0, stdout: "", stderr: ""),
            CommandRunner.Result(exitCode: 164, stdout: "", stderr: "Invalid device: \(udid)\n"),
        ]
        let result = await SimulatorCAInstaller(run: xcrun.runner).reboot(udid: udid)
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.message, "The simulator was not found. It may have been deleted.")
    }
}

/// A fake `xcrun` that records calls and returns queued results (success when the queue is empty).
private final class FakeXcrun: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var results: [CommandRunner.Result] = []
    var inspect: (([String]) -> Void)?

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }

    var runner: SimulatorCAInstaller.Runner {
        { [self] arguments in handle(arguments) }
    }

    private func handle(_ arguments: [String]) -> CommandRunner.Result {
        lock.lock()
        recorded.append(arguments)
        let next = results.isEmpty ? nil : results.removeFirst()
        let hook = inspect
        lock.unlock()
        hook?(arguments)
        return next ?? CommandRunner.Result(exitCode: 0, stdout: "", stderr: "")
    }
}
