import Foundation

/// The one place Jaca asks a booted simulator "is this app running, and as which pid?".
///
/// Logs filters unified-log lines by pid (the bundle id never appears as a process name) and
/// Network watches for an app that came back without the agent — one parser, so a fix to the
/// label shapes lands on both.
enum SimulatorProcesses {
    /// What `launchctl list` says about the target app.
    enum Presence: Sendable, Equatable {
        /// `simctl spawn` couldn't reach the simulator — it was shut down, or never booted.
        case notBooted
        /// The simulator answered and the app isn't there (or is registered with no pid).
        case notRunning
        case running(pid: Int32)
    }

    static func probe(udid: String, bundleID: String) async -> Presence {
        guard let output = await launchctlList(udid: udid) else { return .notBooted }
        guard let pid = pid(bundleID: bundleID, inLaunchctlList: output) else { return .notRunning }
        return .running(pid: pid)
    }

    /// Raw `launchctl list` output, or nil when the simulator isn't reachable. The one process
    /// spawn behind every query here, so no caller can multiply it.
    static func launchctlList(udid: String) async -> String? {
        guard let r = try? await CommandRunner.run(
                  AppleToolchain.xcrun,
                  ["simctl", "spawn", udid, "launchctl", "list"],
                  environment: AppleToolchain.environment()),
              r.exitCode == 0 else { return nil }
        return r.stdout
    }

    // MARK: - Pure parsing

    /// Pure. The pid of the first entry whose launchd label names exactly `bundleID`.
    static func pid(bundleID: String, inLaunchctlList output: String) -> Int32? {
        runningPIDs(bundleID: bundleID, in: output).first
    }

    /// Pure. An app can appear more than once (relaunch races, `rb-legacy` duplicates), and the
    /// log filter wants every pid, not a guess at the current one.
    static func pids(bundleID: String, inLaunchctlList output: String) -> Set<Int32> {
        Set(runningPIDs(bundleID: bundleID, in: output))
    }

    /// Pure.
    static func isRunning(bundleID: String, inLaunchctlList output: String) -> Bool {
        !runningPIDs(bundleID: bundleID, in: output).isEmpty
    }

    /// `"<pid>\t<status>\t<label>"`, one job per line, plus a `PID Status Label` header that falls
    /// out on its own (its label column names no bundle id).
    private static func runningPIDs(bundleID: String, in output: String) -> [Int32] {
        guard !bundleID.isEmpty else { return [] }
        var pids: [Int32] = []
        // `isNewline`, not `== "\n"`: Swift folds CRLF into one Character, so comparing against
        // either half matches nothing on CRLF output.
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let label = fields.last, names(bundleID, label) else { continue }
            // A "-" pid column means launchd knows the job but nothing is running.
            guard let pid = Int32(fields[0]), pid > 0 else { continue }
            pids.append(pid)
        }
        return pids
    }

    /// `UIKitApplication:com.example.App[0x1][1be2]`, `…[6a1f][rb-legacy]` and the bare form all
    /// name `com.example.App` — and none names `com.example.AppExtension`. Hence an exact
    /// comparison once the `[…]` suffixes are cut, never a prefix or `contains`.
    ///
    /// The leading `:` is required: a booted simulator lists ~130 launchd daemons whose whole
    /// label is bundle-id-shaped (`com.apple.SpringBoard`).
    private static func names(_ bundleID: String, _ label: Substring) -> Bool {
        label.prefix { $0 != "[" }.hasSuffix(":" + bundleID)
    }
}
