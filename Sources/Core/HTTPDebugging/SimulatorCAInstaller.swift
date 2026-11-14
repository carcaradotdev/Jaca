import Foundation

/// Why a simulator command failed, in a form the UI can show.
struct SimulatorCAError: Error, Equatable, Sendable {
    let message: String
}

/// Installs Jaca's CA in an iOS Simulator's trusted root store and reboots the simulator.
///
/// The user starts both actions. A capture never calls them by itself.
struct SimulatorCAInstaller: Sendable {
    /// Runs `xcrun <arguments>`. A launch failure comes back as a non-zero exit code.
    typealias Runner = @Sendable (_ arguments: [String]) async -> CommandRunner.Result

    private let run: Runner
    private let temporaryDirectory: URL

    init(run: @escaping Runner = SimulatorCAInstaller.liveRunner,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.run = run
        self.temporaryDirectory = temporaryDirectory
    }

    static let liveRunner: Runner = { arguments in
        do {
            return try await CommandRunner.run(AppleToolchain.xcrun, arguments,
                                               environment: AppleToolchain.environment(),
                                               timeout: 120)
        } catch {
            return CommandRunner.Result(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
    }

    /// Runs `xcrun simctl keychain <udid> add-root-cert <file>` with `caPEM` written to a
    /// temporary file. The simulator must be booted.
    func install(udid: String, caPEM: String) async -> Result<Void, SimulatorCAError> {
        let file = temporaryDirectory.appendingPathComponent("jaca-ca-\(UUID().uuidString).pem")
        do {
            try Data(caPEM.utf8).write(to: file, options: .atomic)
        } catch {
            return .failure(SimulatorCAError(message: error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let result = await run(["simctl", "keychain", udid, "add-root-cert", file.path])
        guard result.exitCode == 0 else {
            return .failure(SimulatorCAError(message: SimctlErrorText.message(from: result)))
        }
        return .success(())
    }

    /// Runs `simctl shutdown`, then `simctl boot`. A simulator that is already shut down, or
    /// already booted, is not an error.
    func reboot(udid: String) async -> Result<Void, SimulatorCAError> {
        let shutdown = await run(["simctl", "shutdown", udid])
        if shutdown.exitCode != 0, !SimctlErrorText.isStateConflict(shutdown, state: "Shutdown") {
            return .failure(SimulatorCAError(message: SimctlErrorText.message(from: shutdown)))
        }
        let boot = await run(["simctl", "boot", udid])
        if boot.exitCode != 0, !SimctlErrorText.isStateConflict(boot, state: "Booted") {
            return .failure(SimulatorCAError(message: SimctlErrorText.message(from: boot)))
        }
        return .success(())
    }
}

/// Turns `simctl` failure output into a readable message.
///
/// `simctl` prints a technical header such as
/// `An error was encountered processing the command (domain=…, code=405):`, then the reason.
/// The message keeps the reason lines and drops the header and the underlying-error lines.
/// When nothing else is left, it keeps the header lines.
enum SimctlErrorText {
    static func message(from result: CommandRunner.Result) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.stdout : result.stderr
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let reasons = lines.filter { !isHeader($0) }
        if reasons.contains(where: { $0.contains("current state: Shutdown") }) {
            return "Boot the simulator, then try again." // COPY-PENDING
        }
        if reasons.contains(where: { $0.hasPrefix("Invalid device") }) {
            return "The simulator was not found. It may have been deleted." // COPY-PENDING
        }
        let shown = reasons.isEmpty ? lines : reasons
        if shown.isEmpty {
            return "simctl exited with code \(result.exitCode)." // COPY-PENDING
        }
        return shown.joined(separator: " ")
    }

    /// True when the output says the device is already in `state`, for example
    /// `Unable to shutdown device in current state: Shutdown`.
    static func isStateConflict(_ result: CommandRunner.Result, state: String) -> Bool {
        (result.stderr + result.stdout).contains("current state: \(state)")
    }

    private static func isHeader(_ line: String) -> Bool {
        line.hasPrefix("An error was encountered processing the command")
            || line.hasPrefix("Underlying error")
    }
}
