import Foundation

/// Parses one `log stream --style ndjson` JSON line into a `LogLine`.
enum SimulatorLogParser {
    private struct Entry: Decodable {
        let timestamp: String?
        let messageType: String?
        let subsystem: String?
        let category: String?
        let processID: Int32?
        let threadID: Int64?
        let eventMessage: String?
        let processImagePath: String?
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return f
    }()

    static func parse(_ raw: String) -> LogLine? {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(",") { trimmed.removeLast() }
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }

        let tag = (entry.subsystem?.isEmpty == false ? entry.subsystem : entry.category) ?? ""
        let process = entry.processImagePath.map { ($0 as NSString).lastPathComponent }
        let timestamp = entry.timestamp.flatMap { formatter.date(from: $0) } ?? Date()

        return LogLine(
            seq: 0,
            timestamp: timestamp,
            level: mapLevel(entry.messageType),
            tag: tag,
            pid: entry.processID ?? 0,
            tid: Int32(truncatingIfNeeded: entry.threadID ?? 0),
            message: entry.eventMessage ?? "",
            raw: raw,
            processName: process
        )
    }

    /// Apple unified logging has no "warn"; map its levels onto ours.
    static func mapLevel(_ type: String?) -> LogLevel {
        switch type {
        case "Debug": return .debug
        case "Info": return .info
        case "Default": return .info
        case "Error": return .error
        case "Fault": return .fatal
        default: return .info
        }
    }
}

/// Streams `xcrun simctl spawn <udid> log stream --style ndjson` for a booted
/// iOS simulator and parses each JSON line.
final class SimulatorLogSource: LogSource {
    private let udid: String
    private let process: StreamingProcess

    init(udid: String) {
        self.udid = udid
        self.process = StreamingProcess(
            executable: AppleToolchain.xcrun,
            arguments: ["simctl", "spawn", udid, "log", "stream",
                        "--style", "ndjson", "--level", "debug"],
            environment: AppleToolchain.environment()
        )
    }

    func start() throws -> AsyncStream<LogLine> {
        let lineStream = try process.start()
        return AsyncStream<LogLine> { continuation in
            let task = Task {
                var seq: UInt64 = 0
                for await raw in lineStream {
                    guard var line = SimulatorLogParser.parse(raw) else { continue }
                    line.seq = seq
                    seq += 1
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { [process] _ in
                task.cancel()
                process.stop()
            }
        }
    }

    func stop() { process.stop() }

    /// Resolves the running PID(s) for a bundle id on a booted simulator. iOS unified-log
    /// lines carry the process id, so we filter by it — the bundle id never appears
    /// as the process name. The `launchctl list` call and its label parsing live in
    /// `SimulatorProcesses`, shared with the Network side's attach watchdog.
    static func resolvePIDs(udid: String, bundleID: String) async -> Set<Int32> {
        guard !bundleID.isEmpty, let output = await SimulatorProcesses.launchctlList(udid: udid)
        else { return [] }
        return SimulatorProcesses.pids(bundleID: bundleID, inLaunchctlList: output)
    }
}
