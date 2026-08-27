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

/// Process-global registry of device proxies Jaca has configured, so they get
/// reverted even when the normal per-session `stop()` teardown can't run.
///
/// Covers graceful quit (`applicationWillTerminate` calls `revertAll`) and the
/// catchable termination signals (SIGINT/SIGTERM/SIGHUP). A `SIGKILL` (Force
/// Quit, OOM) or a hard crash runs no code by definition — the per-device
/// "Revert" affordance in the sidebar is the backstop for that case.
enum ProxyCleanup {
    private struct Entry: Equatable { let adbPath: String; let serial: String }
    private static let lock = NSLock()
    private static var entries: [Entry] = []
    private static var handlersInstalled = false

    /// Record that `serial`'s proxy is configured and arm the signal handlers.
    static func register(adbPath: String, serial: String) {
        lock.lock(); defer { lock.unlock() }
        let entry = Entry(adbPath: adbPath, serial: serial)
        if !entries.contains(entry) { entries.append(entry) }
        installHandlersLocked()
    }

    /// Forget a proxy once it's been cleared the normal way.
    static func deregister(adbPath: String, serial: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { $0 == Entry(adbPath: adbPath, serial: serial) }
    }

    /// Synchronously revert every still-registered proxy. Safe to call from
    /// `applicationWillTerminate`; also invoked from the signal handlers.
    static func revertAll() {
        lock.lock(); let snapshot = entries; lock.unlock()
        for entry in snapshot { runClear(adbPath: entry.adbPath, serial: entry.serial) }
    }

    /// Clears every proxy key synchronously — the quit and catchable-signal path, so it has to be
    /// as complete as the async one.
    ///
    /// No Wi-Fi bounce here: it needs a sleep between disable and enable, and this runs while the
    /// process is terminating. The "Revert device proxy" affordance does the full job.
    private static func runClear(adbPath: String, serial: String) {
        run(adbPath, ["-s", serial, "shell", "settings", "put", "global", "http_proxy", ":0"])
        for key in ProxyConfigurator.proxySettingsKeys {
            run(adbPath, ["-s", serial, "shell", "settings", "delete", "global", key])
        }
    }

    private static func run(_ adbPath: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        process.standardOutput = nil
        process.standardError = nil
        try? process.run()
        process.waitUntilExit()
    }

    private static func installHandlersLocked() {
        guard !handlersInstalled else { return }
        handlersInstalled = true
        // Shared with `AdbTunnelCleanup` (see `TerminationCleanup`): a proxy-only handler here
        // silently disabled tunnel cleanup.
        TerminationCleanup.install()
    }
}
