import Darwin
import Foundation

/// The iOS Simulator that owns a connection to the Mac system proxy.
struct SimulatorAttribution: Equatable, Sendable {
    let udid: String
    let pid: pid_t
}

/// Decides whether a TCP client of our listener is a process of an iOS Simulator.
///
/// The Mac system proxy sends every app on the Mac to our listener. Only a connection from a
/// simulator process may be decrypted and recorded; every other connection is relayed raw. The
/// attributor finds the pid that owns the client socket with libproc, then looks for the UDID:
///
/// 1. `SIMULATOR_UDID` in the process environment. Recent macOS hides the environment of other
///    processes from `KERN_PROCARGS2`, so this often gives nothing.
/// 2. An executable path under `CoreSimulator/Devices/<UDID>/`. This matches installed apps.
/// 3. The same checks on each ancestor, up to `launchd_sim`, whose arguments name the device
///    folder. This matches simulator daemons such as `nsurlsessiond`, which run from the runtime
///    root.
///
/// `attribute` is synchronous and scans every pid, so call it off the main thread and off the
/// NIO event loop (`ProxyServer` runs its `clientPolicy` on a separate queue). A pid that exits during the scan gives no match; nothing here traps.
final class ConnectionAttributor: @unchecked Sendable {
    /// The system calls the attributor uses, injectable so tests never read real processes.
    struct Probe: Sendable {
        /// The pid that owns the TCP socket with local port `clientPort` and remote port
        /// `listenerPort`, or nil.
        var owningPid: @Sendable (_ clientPort: UInt16, _ listenerPort: UInt16) -> pid_t?
        /// The process environment, or nil when it cannot be read.
        var environment: @Sendable (_ pid: pid_t) -> [String: String]?
        /// The executable path, or nil when it cannot be read.
        var executablePath: @Sendable (_ pid: pid_t) -> String?
        /// The process arguments without the executable path, or nil when they cannot be read.
        var arguments: @Sendable (_ pid: pid_t) -> [String]?
        /// The parent pid, or nil when the process has exited.
        var parentPid: @Sendable (_ pid: pid_t) -> pid_t?

        static let live = Probe(
            owningPid: { LibProc.owningPid(clientPort: $0, listenerPort: $1) },
            environment: { LibProc.procArgs2(pid: $0).map { ProcArgs2Parser.parse($0).environment } },
            executablePath: { LibProc.executablePath(pid: $0) },
            arguments: { LibProc.procArgs2(pid: $0).map { ProcArgs2Parser.parse($0).arguments } },
            parentPid: { LibProc.parentPid(pid: $0) }
        )
    }

    private struct CacheEntry {
        let result: SimulatorAttribution?
        let expires: Date
    }

    private let probe: Probe
    private let cacheTTL: TimeInterval
    private let now: @Sendable () -> Date
    private let ownPid: pid_t
    private let lock = NSLock()
    private var byPid: [pid_t: CacheEntry] = [:]

    init(probe: Probe = .live,
         cacheTTL: TimeInterval = 5,
         ownPid: pid_t = ProcessInfo.processInfo.processIdentifier,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.probe = probe
        self.cacheTTL = cacheTTL
        self.ownPid = ownPid
        self.now = now
    }

    /// The simulator that owns the client at `127.0.0.1:clientPort` connected to our
    /// `listenerPort`, or nil when the owner is not a simulator process or cannot be found.
    ///
    /// The owning pid is looked up on every call. A cached result by client port could belong
    /// to a closed connection whose ephemeral port another Mac process now reuses, and that
    /// process's traffic would then be decrypted. Only the ancestry checks are cached, by pid.
    func attribute(clientPort: UInt16, listenerPort: UInt16) -> SimulatorAttribution? {
        let time = now()
        guard let pid = probe.owningPid(clientPort, listenerPort), pid > 0, pid != ownPid else { return nil }

        lock.lock()
        if let hit = byPid[pid], hit.expires > time {
            lock.unlock()
            return hit.result
        }
        lock.unlock()

        let udid = SimulatorProcessMatch.udid(startingAt: pid, probe: probe)
        let result = udid.map { SimulatorAttribution(udid: $0, pid: pid) }

        lock.lock()
        byPid[pid] = CacheEntry(result: result, expires: time.addingTimeInterval(cacheTTL))
        pruneLocked(time: time)
        lock.unlock()
        return result
    }

    private func pruneLocked(time: Date) {
        guard byPid.count > 512 else { return }
        byPid = byPid.filter { $0.value.expires > time }
    }
}

/// Pure rules that tell a simulator process from any other Mac process.
enum SimulatorProcessMatch {
    /// How many ancestors to check. An app is a child of `launchd_sim`, so a few levels suffice.
    static let maxAncestors = 6

    /// The UDID of the simulator that runs `pid`, from the process or one of its ancestors.
    static func udid(startingAt pid: pid_t, probe: ConnectionAttributor.Probe) -> String? {
        var current = pid
        var visited: Set<pid_t> = []
        for _ in 0...maxAncestors {
            guard current > 1, visited.insert(current).inserted else { return nil }
            let path = probe.executablePath(current)
            let isLaunchdSim = path.map(isLaunchdSimPath) ?? false
            if let udid = udid(environment: probe.environment(current),
                               executablePath: path,
                               arguments: isLaunchdSim ? probe.arguments(current) : nil) {
                return udid
            }
            guard let parent = probe.parentPid(current) else { return nil }
            current = parent
        }
        return nil
    }

    /// The simulator UDID from the environment, else from the executable path, else from the
    /// arguments. Pass `arguments` only for `launchd_sim`: any Mac tool can take a device path
    /// as an argument.
    static func udid(environment: [String: String]?, executablePath: String?,
                     arguments: [String]? = nil) -> String? {
        if let value = environment?["SIMULATOR_UDID"], let udid = normalizedUDID(value) {
            return udid
        }
        if let path = executablePath, let udid = udid(fromPath: path) { return udid }
        for argument in arguments ?? [] {
            if let udid = udid(fromPath: argument) { return udid }
        }
        return nil
    }

    static func isLaunchdSimPath(_ path: String) -> Bool {
        path.split(separator: "/").last == "launchd_sim"
    }

    /// The UDID in a path such as
    /// `/Users/me/Library/Developer/CoreSimulator/Devices/<UDID>/data/Containers/…`.
    static func udid(fromPath path: String) -> String? {
        let marker = "/CoreSimulator/Devices/"
        guard let range = path.range(of: marker) else { return nil }
        let rest = path[range.upperBound...]
        guard let component = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first,
              rest.count > component.count else { return nil }
        return normalizedUDID(String(component))
    }

    /// The uppercase UDID, or nil when `value` is not a UUID.
    static func normalizedUDID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return uuid.uuidString
    }
}

/// Parses the `sysctl(KERN_PROCARGS2)` buffer.
///
/// Layout: a 32-bit `argc`, the executable path and its NUL padding, `argc` NUL-terminated
/// arguments (the first is usually the program name), then NUL-terminated `KEY=value`
/// environment strings up to an empty string or the end of the buffer.
enum ProcArgs2Parser {
    struct Parsed: Equatable, Sendable {
        var executable: String = ""
        var arguments: [String] = []
        var environment: [String: String] = [:]
    }

    static func environment(from bytes: [UInt8]) -> [String: String] {
        parse(bytes).environment
    }

    static func parse(_ bytes: [UInt8]) -> Parsed {
        var parsed = Parsed()
        guard bytes.count >= 4 else { return parsed }
        // Host byte order, which is little-endian on every Mac.
        let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let argc = Int(Int32(bitPattern: raw))
        guard argc >= 0 else { return parsed }
        var index = 4

        func nextString() -> String {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            if index < bytes.count { index += 1 }
            return value
        }

        parsed.executable = nextString()
        // The padding after the path.
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        while parsed.arguments.count < argc, index < bytes.count {
            parsed.arguments.append(nextString())
        }

        while index < bytes.count {
            let entry = nextString()
            if entry.isEmpty { break }
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            let key = String(entry[..<eq])
            if parsed.environment[key] == nil {
                parsed.environment[key] = String(entry[entry.index(after: eq)...])
            }
        }
        return parsed
    }
}

/// Thin libproc and sysctl wrappers. Each returns nil when the pid has exited or the call fails.
enum LibProc {
    static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Room for processes that start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { raw in
            proc_listallpids(raw.baseAddress, Int32(raw.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), pids.count))).filter { $0 > 0 }
    }

    /// Scans every process for the TCP socket with local port `clientPort` and remote port
    /// `listenerPort`.
    static func owningPid(clientPort: UInt16, listenerPort: UInt16) -> pid_t? {
        let me = ProcessInfo.processInfo.processIdentifier
        for pid in allPids() where pid != me {
            if ownsSocket(pid: pid, localPort: clientPort, remotePort: listenerPort) { return pid }
        }
        return nil
    }

    static func ownsSocket(pid: pid_t, localPort: UInt16, remotePort: UInt16) -> Bool {
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 16)
        let filled = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return false }
        let count = min(Int(filled) / fdSize, fds.count)
        for fd in fds.prefix(count) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size)
            guard got == size, info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let local = UInt16(truncatingIfNeeded: ini.insi_lport).bigEndian
            let remote = UInt16(truncatingIfNeeded: ini.insi_fport).bigEndian
            if local == localPort, remote == remotePort { return true }
        }
        return false
    }

    static func parentPid(pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(bitPattern: info.pbi_ppid)
    }

    static func procArgs2(pid: pid_t) -> [UInt8]? {
        var maxArg: Int32 = 0
        var maxSize = MemoryLayout<Int32>.size
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMib, 2, &maxArg, &maxSize, nil, 0) == 0, maxArg > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(maxArg))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }
        guard status == 0, size > 0 else { return nil }
        return Array(buffer.prefix(min(size, buffer.count)))
    }

    static func executablePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; Swift does not import the macro.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
