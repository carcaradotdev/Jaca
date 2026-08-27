import Foundation

/// Process-global registry of adb tunnels Jaca created, so they are removed even when the normal
/// per-session `stop()` teardown can't run. Same shape as `ProxyCleanup`.
///
/// It closes a leak predating overrides: `AgentController.stop()` removes its `adb forward` from
/// a detached `Task` that doesn't survive `NSApp.terminate`, so quitting mid-capture stranded one
/// forward per session in the adb server. A stranded **reverse** is worse — it points the
/// device's `localhost:<port>` at a dead listener — which is why the agent also disarms on EOF
/// and heartbeat expiry (`Divert.kt`), where no code of ours runs at all.
enum AdbTunnelCleanup {
    enum Kind: String, Codable, Sendable {
        case forward
        case reverse
    }

    private struct Entry: Equatable {
        let adbPath: String
        let serial: String
        let kind: Kind
        let port: Int
    }

    private static let lock = NSLock()
    private static var entries: [Entry] = []
    private static var handlersInstalled = false

    /// Record a tunnel and arm the signal handlers. Also written to the ledger, so a SIGKILLed
    /// run is cleaned up by the *next* launch.
    static func register(adbPath: String, serial: String, kind: Kind, port: Int) {
        lock.lock()
        let entry = Entry(adbPath: adbPath, serial: serial, kind: kind, port: port)
        if !entries.contains(entry) { entries.append(entry) }
        installHandlersLocked()
        lock.unlock()
        TunnelLedger.add(serial: serial, adbPath: adbPath, kind: kind, port: port)
    }

    /// Forget a tunnel once it's been removed the normal way.
    static func deregister(adbPath: String, serial: String, kind: Kind, port: Int) {
        lock.lock()
        entries.removeAll { $0 == Entry(adbPath: adbPath, serial: serial, kind: kind, port: port) }
        lock.unlock()
        TunnelLedger.remove(serial: serial, kind: kind, port: port)
    }

    /// Synchronously remove every still-registered tunnel, from `applicationWillTerminate` or a
    /// signal handler. Only *this* is synchronous: interactive teardown stays async, so a wedged
    /// device can't block the main thread on `waitUntilExit`.
    static func revertAll() {
        lock.lock(); let snapshot = entries; entries.removeAll(); lock.unlock()
        for entry in snapshot {
            runRemove(adbPath: entry.adbPath, serial: entry.serial, kind: entry.kind, port: entry.port)
            TunnelLedger.remove(serial: entry.serial, kind: entry.kind, port: entry.port)
        }
    }

    /// Removes tunnels left behind by a previous run that died without cleaning up.
    /// Returns how many were reclaimed, so the UI can say so once rather than silently.
    @discardableResult
    static func reconcileOrphansFromPreviousRuns() -> Int {
        let orphans = TunnelLedger.orphans()
        for entry in orphans {
            runRemove(adbPath: entry.adbPath, serial: entry.serial, kind: entry.kind, port: entry.port)
            TunnelLedger.remove(serial: entry.serial, kind: entry.kind, port: entry.port)
        }
        return orphans.count
    }

    private static func runRemove(adbPath: String, serial: String, kind: Kind, port: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", serial, kind.rawValue, "--remove", "tcp:\(port)"]
        process.standardOutput = nil
        process.standardError = nil
        try? process.run()
        process.waitUntilExit()
    }

    private static func installHandlersLocked() {
        guard !handlersInstalled else { return }
        handlersInstalled = true
        TerminationCleanup.install()
    }
}

/// The process's `SIGINT`/`SIGTERM`/`SIGHUP` disposition, installed exactly once.
///
/// `AdbTunnelCleanup` and `ProxyCleanup` each installed their own, so whichever registered second
/// replaced the first and a `SIGTERM` stranded the other's cleanup. One installer, one handler,
/// both reverts, so registration order can't decide what gets cleaned up.
///
/// Spawning `adb` from a signal handler isn't strictly async-signal-safe — a deliberate trade for
/// a dev tool, and it only runs on the way out.
enum TerminationCleanup {
    private static let lock = NSLock()
    private static var installed = false

    static func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { received in
                AdbTunnelCleanup.revertAll()
                ProxyCleanup.revertAll()
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }
}

/// On-disk record of the tunnels this process owns, so a `SIGKILL` — which runs no cleanup code
/// — can be repaired on the next launch. Ownership is by pid: `adb reverse --list` prints bare
/// `tcp:P tcp:P` entries, so it can't tell Jaca's tunnels from anyone else's.
enum TunnelLedger {
    struct Entry: Codable, Sendable, Equatable {
        var serial: String
        var adbPath: String
        var kind: AdbTunnelCleanup.Kind
        var port: Int
        var pid: Int32
        var createdAt: Date

        init(serial: String, adbPath: String, kind: AdbTunnelCleanup.Kind, port: Int,
             pid: Int32, createdAt: Date = Date()) {
            self.serial = serial
            self.adbPath = adbPath
            self.kind = kind
            self.port = port
            self.pid = pid
            self.createdAt = createdAt
        }
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jaca/network/tunnels.json")
    }

    private static let lock = NSLock()

    static func add(serial: String, adbPath: String, kind: AdbTunnelCleanup.Kind, port: Int) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        let entry = Entry(serial: serial, adbPath: adbPath, kind: kind, port: port,
                          pid: ProcessInfo.processInfo.processIdentifier)
        all.removeAll { $0.serial == serial && $0.kind == kind && $0.port == port }
        all.append(entry)
        saveLocked(all)
    }

    static func remove(serial: String, kind: AdbTunnelCleanup.Kind, port: Int) {
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        all.removeAll { $0.serial == serial && $0.kind == kind && $0.port == port }
        saveLocked(all)
    }

    static func load() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Entries whose owning process is gone — the ones safe to remove.
    /// How long an entry may sit before it counts as abandoned regardless of its pid. Pids are
    /// recycled, so a killed owner whose number lands on a live process would look alive forever
    /// and `tunnels.json` would grow across crashes. A week beats any real session, and firing
    /// early is benign: it removes an `adb reverse` Jaca would have removed on exit anyway.
    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    /// Whether an entry belongs to nobody any more. Pure, so the table can be asserted without
    /// a real pid or the ledger.
    static func isAbandoned(entry: Entry, isOwnPid: Bool, pidAlive: Bool, now: Date) -> Bool {
        if isOwnPid { return false }
        if !pidAlive { return true }
        return now.timeIntervalSince(entry.createdAt) > staleAfter
    }

    static func orphans(now: Date = Date()) -> [Entry] {
        let me = ProcessInfo.processInfo.processIdentifier
        return load().filter {
            isAbandoned(entry: $0, isOwnPid: $0.pid == me, pidAlive: isProcessAlive($0.pid), now: now)
        }
    }

    /// `kill(pid, 0)` probes for existence without signalling. `EPERM` means it exists but
    /// belongs to someone else, so it is *not* an orphan.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func loadLocked() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return CloudPersistence.decodeArray(Entry.self, from: data, decoder: makeDecoder())
    }

    private static func saveLocked(_ entries: [Entry]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? makeEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Must mirror `makeEncoder()` exactly. They drifted once — ISO-8601 out, numeric in — so
    /// `createdAt` threw `typeMismatch`, every record was dropped, and the ledger silently read
    /// as empty: no orphan was ever reclaimed and each `add()` truncated the file.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// Tolerant decode, per the house rule for anything persisted to `~/.jaca`.
extension TunnelLedger.Entry {
    enum CodingKeys: String, CodingKey { case serial, adbPath, kind, port, pid, createdAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serial    = try c.decodeIfPresent(String.self, forKey: .serial) ?? ""
        adbPath   = try c.decodeIfPresent(String.self, forKey: .adbPath) ?? ""
        kind      = try c.decodeIfPresent(AdbTunnelCleanup.Kind.self, forKey: .kind) ?? .forward
        port      = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        pid       = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
