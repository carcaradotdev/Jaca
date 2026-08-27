import Foundation

/// Jaca's own diagnostic log — `~/.jaca/logs/jaca.log`.
///
/// Jaca is launched with `open Jaca.app`, so `print` goes nowhere a user can see, and the device's
/// logcat says nothing about the desktop side of "it worked, then it stopped".
///
/// Dependency-free and synchronous-append behind a lock, because it has to work while the thing
/// it is diagnosing is broken. Rotated at a fixed size so it can't grow unbounded.
enum JacaLog {

    enum Level: String {
        case debug = "DEBUG"
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERROR"
    }

    /// Roll over at 2 MB, keeping one previous file. Enough for a long session, bounded on disk.
    private static let maxBytes = 2 * 1024 * 1024

    private static let lock = NSLock()

    /// Verbose logging, off by default. `append` is a synchronous write under a process-global
    /// lock and `debug` runs on hot paths — once per bounced request, for a whole diverted host —
    /// so ungated it blocks NIO event loops and churns the 2 MB rotation past anything useful.
    static let verboseKey = "diagnosticsVerboseLogging"
    static var verboseEnabled: Bool {
        // Reads the cache, not `UserDefaults`, so callers see the value `debug` actually gates
        // on — a default written outside this setter could otherwise disagree forever.
        get { verboseLock.lock(); defer { verboseLock.unlock() }; return cachedVerbose }
        set {
            UserDefaults.standard.set(newValue, forKey: verboseKey)
            verboseLock.lock(); cachedVerbose = newValue; verboseLock.unlock()
        }
    }

    /// Cached because the gate sits in front of a per-request call, and locked because event
    /// loops and reader threads read it while the Settings toggle writes from the main thread.
    private static let verboseLock = NSLock()
    nonisolated(unsafe) private static var cachedVerbose: Bool = UserDefaults.standard.bool(forKey: verboseKey)

    /// `DateFormatter` isn't thread-safe and lines are formatted from event loops too, so it is
    /// only ever touched while holding `lock`.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jaca/logs", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("jaca.log") }
    static var previousFileURL: URL { directory.appendingPathComponent("jaca.log.1") }

    /// Writes one line. `category` groups related subsystems (e.g. "override", "agent").
    static func write(_ level: Level, _ category: String, _ message: String) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        // Inside the lock: `DateFormatter` isn't thread-safe and event loops reach this.
        append("\(formatter.string(from: now)) [\(level.rawValue)] [\(category)] \(message)\n")
    }

    /// Dropped unless verbose logging is on. The caller builds the message either way, so keep
    /// `debug` call sites free of expensive interpolation.
    static func debug(_ category: String, _ message: String) {
        guard verboseEnabled else { return }
        write(.debug, category, message)
    }
    static func info(_ category: String, _ message: String)  { write(.info, category, message) }
    static func warn(_ category: String, _ message: String)  { write(.warn, category, message) }
    static func error(_ category: String, _ message: String) { write(.error, category, message) }

    /// The most recent `limit` lines, newest last — for showing recent activity in the UI.
    static func tail(_ limit: Int = 200, category: String? = nil) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let category { lines = lines.filter { $0.contains("[\(category)]") } }
        return Array(lines.suffix(limit))
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size]) as? Int, size > maxBytes {
            try? fm.removeItem(at: previousFileURL)
            try? fm.moveItem(at: fileURL, to: previousFileURL)
        }

        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
