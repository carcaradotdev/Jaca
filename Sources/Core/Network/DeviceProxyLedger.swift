import Foundation

/// A JSON array of records in one file, read and written under a lock.
///
/// The app and jacad both write these files, so the lock is two locks: an `NSLock` for the
/// threads of this process, and an advisory `flock` on a sibling `<name>.lock` file for the
/// other process. Without the `flock`, two processes that each load, change and save lose
/// one another's records.
///
/// The device proxy ledger uses it, and any other cross-launch record of a change Jaca made
/// (the Mac system proxy lease, for example) can use it too. Reads go through
/// `CloudPersistence.decodeArray`, so one unreadable record never empties the file. The encoder
/// and the decoder both use ISO-8601 dates; a mismatch drops every record silently (see
/// `TunnelLedger.makeDecoder`).
final class JSONLedgerFile<Record: Codable>: @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// All records. A missing or unreadable file reads as empty.
    func load() -> [Record] {
        lock.lock(); defer { lock.unlock() }
        return withFileLock { loadLocked() }
    }

    /// Reads the records, applies `change`, and writes the result back, all under the lock, so
    /// two writers in this process can't lose each other's records. Returns what `change` returns.
    @discardableResult
    func update<T>(_ change: (inout [Record]) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return withFileLock {
            var records = loadLocked()
            let result = change(&records)
            saveLocked(records)
            return result
        }
    }

    /// Runs `body` under an exclusive `flock` on `<name>.lock`. When the lock file can't be
    /// opened, `body` still runs: a lost record is better than a capture that can't start.
    private func withFileLock<T>(_ body: () -> T) -> T {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockPath = dir.appendingPathComponent(fileURL.lastPathComponent + ".lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            JacaLog.error("proxy", "couldn't open \(lockPath); writing without the file lock")
            return body()
        }
        flock(fd, LOCK_EX)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return body()
    }

    private func loadLocked() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return CloudPersistence.decodeArray(Record.self, from: data, decoder: Self.makeDecoder())
    }

    private func saveLocked(_ records: [Record]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? Self.makeEncoder().encode(records) else {
            JacaLog.error("proxy", "couldn't encode \(fileURL.lastPathComponent)")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            JacaLog.error("proxy", "couldn't write \(fileURL.path): \(error.localizedDescription)")
        }
    }

    /// Must mirror `makeEncoder()`.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// What `adb shell settings get global http_proxy` told us about a device.
enum AndroidProxyReading: Equatable, Sendable {
    /// adb couldn't reach the device (offline, unplugged, unauthorized).
    case unreachable
    /// The device has no global proxy (`:0`, `null` or empty).
    case noProxy
    /// The device's global proxy, as `host:port`.
    case value(String)

    /// Maps one `settings get` result. A non-zero exit or a launch failure means the device
    /// can't be read, which is different from a device with no proxy.
    static func parse(exitCode: Int32?, stdout: String) -> AndroidProxyReading {
        guard let exitCode, exitCode == 0 else { return .unreachable }
        let value = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == ":0" || value == "null" { return .noProxy }
        return .value(value)
    }

    var proxyValue: String? {
        if case .value(let v) = self { return v }
        return nil
    }
}

/// The adb operations the ledger reconcile needs, as closures so tests never touch a device.
struct AndroidProxyCommands: Sendable {
    var read: @Sendable (_ adbURL: URL, _ serial: String) async -> AndroidProxyReading
    var set: @Sendable (_ adbURL: URL, _ serial: String, _ value: String) async -> Void
    var clear: @Sendable (_ adbURL: URL, _ serial: String) async -> Void

    static let live = AndroidProxyCommands(
        read: { adbURL, serial in await ProxyConfigurator.readAndroidProxy(adbURL: adbURL, serial: serial) },
        set: { adbURL, serial, value in
            await ProxyConfigurator.setAndroidProxyValue(adbURL: adbURL, serial: serial, value: value)
        },
        clear: { adbURL, serial in await ProxyConfigurator.clearAndroidProxy(adbURL: adbURL, serial: serial) }
    )
}

/// On-disk record of the device proxies Jaca set (`settings put global http_proxy 127.0.0.1:P`),
/// so a `SIGKILL`, which runs no cleanup code, can be repaired on the next start.
///
/// It is a separate file from `TunnelLedger` on purpose: an older build skips a tunnel entry with
/// an unknown kind, and would lose that entry's cleanup.
///
/// Write the entry before the device changes. Remove it only after the device is reverted.
enum DeviceProxyLedger {
    struct Entry: Codable, Sendable, Equatable {
        var serial: String
        var adbPath: String
        var port: Int
        /// What Jaca wrote to `http_proxy`, for example `127.0.0.1:41234`.
        var value: String
        /// The device's proxy before Jaca changed it. Nil when it had none.
        var previous: String?
        var pid: Int32
        var createdAt: Date
        /// True when the owner stopped its capture but couldn't revert the device. No capture
        /// holds the value any more, even while the owner runs, so reconcile and the sidebar
        /// "Revert" may repair it.
        var released: Bool

        init(serial: String, adbPath: String, port: Int, value: String, previous: String?,
             pid: Int32 = ProcessInfo.processInfo.processIdentifier, createdAt: Date = Date(),
             released: Bool = false) {
            self.serial = serial
            self.adbPath = adbPath
            self.port = port
            self.value = value
            self.previous = previous
            self.pid = pid
            self.createdAt = createdAt
            self.released = released
        }
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jaca/network/device-proxies.json")
    }

    static let shared = JSONLedgerFile<Entry>(fileURL: fileURL)

    /// Same rule as `TunnelLedger.staleAfter`: pids are recycled, so an entry this old counts as
    /// abandoned even when its pid is alive.
    static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    /// Whether the process that owns an entry still runs. It also checks that the pid still
    /// belongs to Jaca or jacad: after a reboot or a SIGKILL the pid can be another program's,
    /// and `kill(pid, 0)` alone would keep the stranded entry for `staleAfter`.
    static let liveOwnerCheck: @Sendable (Int32) -> Bool = { pid in
        guard TunnelLedger.isProcessAlive(pid) else { return false }
        guard let path = LibProc.executablePath(pid: pid) else { return true }
        return isJacaExecutable(path)
    }

    /// True for the app's or jacad's executable path (`…/Jaca.app/Contents/MacOS/Jaca`,
    /// `…/MacOS/jacad`, or the `jaca` CLI link).
    static func isJacaExecutable(_ path: String) -> Bool {
        path.lowercased().contains("jaca")
    }

    // MARK: - Records

    /// Records `entry`, replacing an earlier one for the same serial and port.
    static func add(_ entry: Entry, in file: JSONLedgerFile<Entry> = shared) {
        file.update { all in
            all.removeAll { $0.serial == entry.serial && $0.port == entry.port }
            all.append(entry)
        }
    }

    /// Records that this process is about to point `serial` at Jaca's proxy on `127.0.0.1:port`.
    /// `previous` is the device's proxy before the change (`currentAndroidProxy`).
    static func add(serial: String, adbPath: String, port: Int, previous: String?,
                    in file: JSONLedgerFile<Entry> = shared) {
        add(Entry(serial: serial, adbPath: adbPath, port: port,
                  value: DeviceProxyPlan.loopbackValue(port: port), previous: previous), in: file)
    }

    static func remove(serial: String, port: Int, in file: JSONLedgerFile<Entry> = shared) {
        file.update { all in all.removeAll { $0.serial == serial && $0.port == port } }
    }

    /// Marks the entry as released: its capture stopped, but the device still has the value.
    static func markReleased(serial: String, port: Int, in file: JSONLedgerFile<Entry> = shared) {
        file.update { all in
            for index in all.indices where all[index].serial == serial && all[index].port == port {
                all[index].released = true
            }
        }
    }

    static func entries(serial: String, in file: JSONLedgerFile<Entry> = shared) -> [Entry] {
        file.load().filter { $0.serial == serial }
    }

    static func entry(serial: String, port: Int, in file: JSONLedgerFile<Entry> = shared) -> Entry? {
        file.load().first { $0.serial == serial && $0.port == port }
    }

    static func load(in file: JSONLedgerFile<Entry> = shared) -> [Entry] {
        file.load()
    }

    // MARK: - Decisions (pure)

    /// Whether reconcile may revert the device for `entry`. True only when all of these hold:
    /// - another process owns the entry;
    /// - that process is dead, or the entry is older than `staleAfter`;
    /// - the device still reads exactly the value Jaca wrote. A different value means somebody
    ///   changed it after Jaca, and Jaca must not overwrite it.
    static func shouldRevert(entry: Entry, current: String?, pidAlive: Bool, isOwnPid: Bool,
                             now: Date) -> Bool {
        guard isAbandoned(entry: entry, pidAlive: pidAlive, isOwnPid: isOwnPid, now: now) else {
            return false
        }
        return current == entry.value
    }

    /// A released entry is abandoned whoever owns it: its capture is gone.
    static func isAbandoned(entry: Entry, pidAlive: Bool, isOwnPid: Bool, now: Date) -> Bool {
        if entry.released { return true }
        if isOwnPid { return false }
        if !pidAlive { return true }
        return now.timeIntervalSince(entry.createdAt) > staleAfter
    }

    enum ReconcileAction: Equatable, Sendable {
        /// Leave the entry and the device alone.
        case keep
        /// Put `previous` back, or clear the proxy when `previous` is nil, then drop the entry.
        case revert(restore: String?)
        /// The device no longer has Jaca's value. Drop the entry and don't touch the device.
        case forget
    }

    /// What reconcile does with one entry.
    ///
    /// - An unreachable device keeps its entry until it is back.
    /// - `otherValues` are the values of the other ledger entries for the same serial. A
    ///   `previous` that matches one of them is an older stranded Jaca proxy, so the proxy is
    ///   cleared instead of restored.
    static func reconcileAction(entry: Entry, reading: AndroidProxyReading, pidAlive: Bool,
                                isOwnPid: Bool, now: Date, otherValues: Set<String>) -> ReconcileAction {
        guard isAbandoned(entry: entry, pidAlive: pidAlive, isOwnPid: isOwnPid, now: now) else {
            return .keep
        }
        switch reading {
        case .unreachable:
            return .keep
        case .noProxy, .value:
            guard shouldRevert(entry: entry, current: reading.proxyValue, pidAlive: pidAlive,
                               isOwnPid: isOwnPid, now: now) else { return .forget }
            return .revert(restore: restoreTarget(previous: entry.previous, otherValues: otherValues))
        }
    }

    /// The value to put back on revert, or nil to clear the proxy.
    ///
    /// A `previous` that is a loopback value of the kind Jaca writes is cleared, not restored,
    /// even when no ledger entry has it any more: it is another Jaca capture's proxy (two
    /// captures overlapped on the device), and its `adb reverse` is gone with that capture.
    static func restoreTarget(previous: String?, otherValues: Set<String>) -> String? {
        guard DeviceProxyPlan.isRestorable(previous), let previous else { return nil }
        if DeviceProxyPlan.isLoopbackValue(previous) { return nil }
        return otherValues.contains(previous) ? nil : previous
    }

    // MARK: - Reconcile

    /// Reverts the device proxies that a dead or stale owner left behind, and drops their entries.
    ///
    /// Run it at jacad start, at app start, and before a capture opens on a serial (pass
    /// `serial`). An entry whose device is unreachable stays for the next run. Returns the
    /// serials that were reverted.
    ///
    /// - Parameter adbPath: the adb to use when an entry has no usable `adbPath`.
    @discardableResult
    static func reconcileOrphans(
        adbPath: String?,
        serial: String? = nil,
        in file: JSONLedgerFile<Entry> = shared,
        commands: AndroidProxyCommands = .live,
        pidAlive: @Sendable (Int32) -> Bool = DeviceProxyLedger.liveOwnerCheck,
        ownPid: Int32 = ProcessInfo.processInfo.processIdentifier,
        isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        now: Date = Date()
    ) async -> [String] {
        let all = file.load()
        let candidates = all.filter { serial == nil || $0.serial == serial }
        var reverted: [String] = []
        for entry in candidates {
            let alive = pidAlive(entry.pid)
            let own = entry.pid == ownPid
            guard isAbandoned(entry: entry, pidAlive: alive, isOwnPid: own, now: now) else { continue }
            guard let adb = usableAdbPath(entry: entry.adbPath, fallback: adbPath,
                                          isExecutable: isExecutable) else {
                JacaLog.error("proxy", "no adb to reconcile the device proxy on \(entry.serial)")
                continue
            }
            let adbURL = URL(fileURLWithPath: adb)
            let reading = await commands.read(adbURL, entry.serial)
            let others = Set(all.filter { $0.serial == entry.serial && $0.port != entry.port }.map(\.value))
            switch reconcileAction(entry: entry, reading: reading, pidAlive: alive, isOwnPid: own,
                                   now: now, otherValues: others) {
            case .keep:
                continue
            case .forget:
                JacaLog.info("proxy", "dropping ledger entry for \(entry.serial):\(entry.port); the device proxy changed")
                remove(serial: entry.serial, port: entry.port, in: file)
            case .revert(let restore):
                if let restore {
                    await commands.set(adbURL, entry.serial, restore)
                } else {
                    await commands.clear(adbURL, entry.serial)
                }
                // Keep the entry when the device still reads Jaca's value, so the next run retries.
                let after = await commands.read(adbURL, entry.serial)
                if after == .value(entry.value) {
                    JacaLog.error("proxy", "couldn't revert the stranded device proxy on \(entry.serial)")
                    continue
                }
                JacaLog.info("proxy", "reverted a stranded device proxy on \(entry.serial) (\(entry.value))")
                remove(serial: entry.serial, port: entry.port, in: file)
                reverted.append(entry.serial)
            }
        }
        return reverted
    }

    /// The entry's adb when it still exists, else the fallback when that exists.
    static func usableAdbPath(entry: String, fallback: String?,
                              isExecutable: (String) -> Bool) -> String? {
        if !entry.isEmpty, isExecutable(entry) { return entry }
        if let fallback, !fallback.isEmpty, isExecutable(fallback) { return fallback }
        return nil
    }
}

/// Tolerant decode, per the house rule for anything persisted to `~/.jaca`.
extension DeviceProxyLedger.Entry {
    enum CodingKeys: String, CodingKey { case serial, adbPath, port, value, previous, pid, createdAt, released }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serial    = try c.decodeIfPresent(String.self, forKey: .serial) ?? ""
        adbPath   = try c.decodeIfPresent(String.self, forKey: .adbPath) ?? ""
        port      = try c.decodeIfPresent(Int.self, forKey: .port) ?? 0
        value     = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        previous  = try c.decodeIfPresent(String.self, forKey: .previous) ?? nil
        pid       = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        released  = try c.decodeIfPresent(Bool.self, forKey: .released) ?? false
    }
}
