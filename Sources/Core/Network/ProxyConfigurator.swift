import Foundation

/// Helpers to point a device at our proxy and to discover the host address the
/// device should use to reach it.
enum ProxyConfigurator {
    /// Host the device uses to reach this Mac: emulators use the magic 10.0.2.2;
    /// physical devices use the Mac's LAN IP.
    static func hostAddress(for device: Device) -> String {
        if device.platform == .android && device.id.hasPrefix("emulator-") {
            return "10.0.2.2"
        }
        return NetworkInterfaces.primaryIPv4() ?? "127.0.0.1"
    }

    static func setAndroidProxy(adbURL: URL, serial: String, host: String, port: Int) async {
        _ = try? await CommandRunner.run(
            adbURL, ["-s", serial, "shell", "settings", "put", "global", "http_proxy", "\(host):\(port)"]
        )
    }

    /// Writes `value` (`host:port`) to the device's global `http_proxy`. Returns true when adb
    /// exited 0.
    @discardableResult
    static func setAndroidProxyValue(adbURL: URL, serial: String, value: String) async -> Bool {
        let r = try? await CommandRunner.run(adbURL, DeviceProxyPlan.setProxy(serial: serial, value: value))
        return r?.exitCode == 0
    }

    /// Reads the device's global `http_proxy`, and tells an unreachable device apart from a
    /// device with no proxy.
    static func readAndroidProxy(adbURL: URL, serial: String) async -> AndroidProxyReading {
        let r = try? await CommandRunner.run(adbURL, DeviceProxyPlan.readProxy(serial: serial))
        return AndroidProxyReading.parse(exitCode: r?.exitCode, stdout: r?.stdout ?? "")
    }

    /// Every settings key that has to be cleared to truly remove a device proxy. `http_proxy`
    /// alone is **not enough**: Android also stores the proxy per-network in `global_http_proxy_*`,
    /// and while those rows survive the network stays unvalidated ("connected, no internet") even
    /// though `http_proxy` reads `:0`.
    static let proxySettingsKeys = [
        "global_http_proxy_host",
        "global_http_proxy_port",
        "global_http_proxy_exclusion_list",
    ]

    /// Clears the device proxy completely and nudges the network back to validated.
    static func clearAndroidProxy(adbURL: URL, serial: String) async {
        _ = try? await CommandRunner.run(
            adbURL, ["-s", serial, "shell", "settings", "put", "global", "http_proxy", ":0"]
        )
        for key in proxySettingsKeys {
            _ = try? await CommandRunner.run(
                adbURL, ["-s", serial, "shell", "settings", "delete", "global", key]
            )
        }
        await revalidateAndroidNetwork(adbURL: adbURL, serial: serial)
    }

    /// Bounces Wi-Fi so Android re-runs its connectivity check. Proxy config is cached per
    /// network, so without this the device sits on a stale unvalidated network.
    static func revalidateAndroidNetwork(adbURL: URL, serial: String) async {
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "svc", "wifi", "disable"])
        try? await Task.sleep(for: .seconds(2))
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "svc", "wifi", "enable"])
    }

    /// True when any proxy key is still set — including the per-network rows that
    /// `currentAndroidProxy` can't see. Drives the "revert" affordance.
    static func hasAnyProxyConfigured(adbURL: URL, serial: String) async -> Bool {
        if await currentAndroidProxy(adbURL: adbURL, serial: serial) != nil { return true }
        for key in proxySettingsKeys {
            let r = try? await CommandRunner.run(
                adbURL, ["-s", serial, "shell", "settings", "get", "global", key])
            let value = (r?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, value != "null", value != "0" { return true }
        }
        return false
    }

    /// The device's current global HTTP proxy, or nil when none is set
    /// (`:0` / `null` / empty all mean "no proxy").
    static func currentAndroidProxy(adbURL: URL, serial: String) async -> String? {
        let r = try? await CommandRunner.run(
            adbURL, ["-s", serial, "shell", "settings", "get", "global", "http_proxy"]
        )
        let value = (r?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == ":0" || value == "null" { return nil }
        return value
    }

    /// Host portion of a `host:port` proxy string (port is ephemeral per run).
    static func proxyHost(_ proxy: String) -> String {
        String(proxy.split(separator: ":").first ?? Substring(proxy))
    }

    /// Pushes the root CA to the device's shared storage for easy manual install.
    static func pushCACertToAndroid(adbURL: URL, serial: String, caPEM: URL) async -> Bool {
        let result = try? await CommandRunner.run(
            adbURL, ["-s", serial, "push", caPEM.path, "/sdcard/Download/JacaProxyCA.pem"]
        )
        return result?.exitCode == 0
    }
}

/// Resolves the Mac's primary non-loopback IPv4 address (for physical-device proxy).
enum NetworkInterfaces {
    static func primaryIPv4() -> String? {
        var address: String?
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            let family = ptr.pointee.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
            break
        }
        return address
    }
}

/// The adb argument lists for the device proxy, as pure functions so tests can assert them.
/// Every list starts with `-s <serial>`.
enum DeviceProxyPlan {
    /// The value Jaca writes to `http_proxy`. The device reaches it through `adb reverse`.
    static func loopbackValue(port: Int) -> String { "127.0.0.1:\(port)" }

    static func reverseAdd(serial: String, port: Int) -> [String] {
        AdbReverseTunnel.openArguments(serial: serial, port: port)
    }

    static func reverseRemove(serial: String, port: Int) -> [String] {
        AdbReverseTunnel.removeArguments(serial: serial, port: port)
    }

    static func setProxy(serial: String, value: String) -> [String] {
        ["-s", serial, "shell", "settings", "put", "global", "http_proxy", value]
    }

    /// Points the device at Jaca's proxy on `127.0.0.1:port`.
    static func arm(serial: String, port: Int) -> [String] {
        setProxy(serial: serial, value: loopbackValue(port: port))
    }

    static func restorePrevious(serial: String, previous: String) -> [String] {
        setProxy(serial: serial, value: previous)
    }

    static func readProxy(serial: String) -> [String] {
        ["-s", serial, "shell", "settings", "get", "global", "http_proxy"]
    }

    /// Removes the proxy: `http_proxy` to `:0`, then each per-network key deleted. It does not
    /// bounce Wi-Fi; `ProxyConfigurator.clearAndroidProxy` does that after these commands.
    static func clear(serial: String) -> [[String]] {
        [setProxy(serial: serial, value: ":0")]
            + ProxyConfigurator.proxySettingsKeys.map {
                ["-s", serial, "shell", "settings", "delete", "global", $0]
            }
    }

    /// The commands that undo `arm`: put `previous` back when it is a real proxy, else clear.
    static func revert(serial: String, previous: String?) -> [[String]] {
        if isRestorable(previous), let previous {
            return [restorePrevious(serial: serial, previous: previous)]
        }
        return clear(serial: serial)
    }

    /// True for a value of the form `loopbackValue` writes: `127.0.0.1:<port>`.
    static func isLoopbackValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("127.0.0.1:") else { return false }
        return Int(trimmed.dropFirst("127.0.0.1:".count)) != nil
    }

    /// True when `previous` names a proxy to put back (not nil, empty, `:0` or `null`).
    static func isRestorable(_ previous: String?) -> Bool {
        guard let value = previous?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !value.isEmpty && value != ":0" && value != "null"
    }
}

/// Process-global registry of device proxies Jaca has configured, so they get
/// reverted even when the normal per-session `stop()` teardown can't run.
///
/// Covers graceful quit (`applicationWillTerminate` calls `revertAll`) and the
/// catchable termination signals (SIGINT/SIGTERM/SIGHUP). A `SIGKILL` (Force
/// Quit, OOM) or a hard crash runs no code by definition. `DeviceProxyLedger.reconcileOrphans`
/// repairs that case on the next start, and the per-device "Revert" affordance in the sidebar
/// is the last backstop.
enum ProxyCleanup {
    private struct Entry: Equatable {
        let adbPath: String
        let serial: String
        let port: Int
        let value: String
    }
    private static let lock = NSLock()
    private static var entries: [Entry] = []
    private static var handlersInstalled = false

    /// Record that `serial`'s proxy is set to `value` (Jaca's proxy on `port`) and arm the signal
    /// handlers. The caller writes the `DeviceProxyLedger` entry before it changes the device.
    static func register(adbPath: String, serial: String, port: Int, value: String) {
        lock.lock(); defer { lock.unlock() }
        let entry = Entry(adbPath: adbPath, serial: serial, port: port, value: value)
        if !entries.contains(entry) { entries.append(entry) }
        installHandlersLocked()
    }

    /// Forget one proxy once it's been reverted the normal way.
    static func deregister(adbPath: String, serial: String, port: Int) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.adbPath == adbPath && $0.serial == serial && $0.port == port }
    }

    /// Forget every proxy on `serial`, after the sidebar "Revert" cleared the device.
    static func deregister(adbPath: String, serial: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0.adbPath == adbPath && $0.serial == serial }
    }

    /// Synchronously revert every still-registered proxy. Compare-and-restore: a device that no
    /// longer reads Jaca's value is left alone. The ledger entry is dropped only when the device
    /// is off Jaca's value; when adb failed or the device is unplugged, the entry stays, so the
    /// next start or the sidebar "Revert" can repair it. Safe to call from
    /// `applicationWillTerminate`; also invoked from the signal handlers.
    static func revertAll() {
        lock.lock(); let snapshot = entries; entries.removeAll(); lock.unlock()
        for entry in snapshot {
            let recorded = DeviceProxyLedger.entries(serial: entry.serial)
            let others = Set(recorded.filter { $0.port != entry.port }.map(\.value))
            let previous = recorded.first { $0.port == entry.port }?.previous
            let read = { () -> AndroidProxyReading in
                let r = run(entry.adbPath, DeviceProxyPlan.readProxy(serial: entry.serial))
                return AndroidProxyReading.parse(exitCode: r?.status, stdout: r?.stdout ?? "")
            }
            let reverted = quitRevert(value: entry.value, previous: previous, otherValues: others,
                                      serial: entry.serial, read: read,
                                      apply: { run(entry.adbPath, $0)?.status == 0 })
            if reverted {
                DeviceProxyLedger.remove(serial: entry.serial, port: entry.port)
            } else {
                JacaLog.error("proxy", "couldn't revert the device proxy on \(entry.serial) at quit; the ledger keeps it")
            }
        }
    }

    /// The quit-time revert of one proxy, with adb as closures so tests can drive it. Returns
    /// true when the device is off `value` afterwards (or already was).
    static func quitRevert(value: String, previous: String?, otherValues: Set<String>, serial: String,
                           read: () -> AndroidProxyReading, apply: ([String]) -> Bool) -> Bool {
        let before = read()
        guard before == .value(value) else { return DeviceProxyOps.isReverted(before, value: value) }
        let restore = DeviceProxyLedger.restoreTarget(previous: previous, otherValues: otherValues)
        var allApplied = true
        for arguments in DeviceProxyPlan.revert(serial: serial, previous: restore) {
            if !apply(arguments) { allApplied = false }
        }
        guard allApplied else { return false }
        return DeviceProxyOps.isReverted(read(), value: value)
    }

    /// No Wi-Fi bounce here: it needs a sleep between disable and enable, and this runs while the
    /// process is terminating. The "Revert device proxy" affordance does the full job.
    /// Returns the exit status and stdout, or nil when adb is missing or couldn't launch.
    @discardableResult
    private static func run(_ adbPath: String, _ arguments: [String]) -> (status: Int32, stdout: String)? {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = nil
        do {
            try process.run()
            // `settings get` prints one short line, so reading to EOF before the wait can't
            // fill the pipe and block.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    private static func installHandlersLocked() {
        guard !handlersInstalled else { return }
        handlersInstalled = true
        // Shared with `AdbTunnelCleanup` (see `TerminationCleanup`): a proxy-only handler here
        // silently disabled tunnel cleanup.
        TerminationCleanup.install()
    }
}
