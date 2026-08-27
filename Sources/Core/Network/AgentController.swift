import Foundation

/// Parses one agent JSON line into a NetworkTransaction. Pure & testable.
enum AgentTransactionParser {
    static func parse(_ line: String) -> NetworkTransaction? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "txn" else { return nil }

        let url = obj["url"] as? String ?? ""
        let comps = URLComponents(string: url)
        var txn = NetworkTransaction(
            method: obj["method"] as? String ?? "GET",
            url: url,
            host: comps?.host ?? "",
            scheme: comps?.scheme ?? (url.hasPrefix("https") ? "https" : "http"),
            requestHeaders: headers(obj["requestHeaders"]),
            requestBody: bodyData(obj["requestBody"]),
            startedAt: date(obj["startedAt"]) ?? Date()
        )
        if let status = obj["status"] as? Int, status > 0 { txn.statusCode = status }
        txn.responseHeaders = headers(obj["responseHeaders"])
        txn.responseBody = bodyData(obj["responseBody"])
        txn.responseContentType = txn.responseHeaders.first { $0.name.lowercased() == "content-type" }?.value
        txn.responseReceivedAt = date(obj["responseAt"])
        txn.finishedAt = date(obj["finishedAt"])
        txn.requestBytes = obj["requestSize"] as? Int ?? (txn.requestBody?.count ?? 0)
        txn.responseBytes = obj["responseSize"] as? Int ?? (txn.responseBody?.count ?? 0)
        txn.error = obj["error"] as? String
        txn.callStack = (obj["callStack"] as? [Any])?.compactMap { $0 as? String }
        txn.httpStack = obj["httpStack"] as? String
        // The agent captures our stamp on the way back, so the row knows it was overridden
        // without the desktop having to match up ids across two different id spaces.
        txn.overriddenByRuleID = txn.responseHeaders
            .first { $0.name.lowercased() == OverrideHeaders.override.lowercased() }
            .flatMap { UUID(uuidString: $0.value) }
        return txn
    }

    private static func headers(_ any: Any?) -> [HeaderPair] {
        guard let dict = any as? [String: Any] else { return [] }
        return dict.map { HeaderPair(name: $0.key, value: "\($0.value)") }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    private static func bodyData(_ any: Any?) -> Data? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return s.data(using: .utf8)
    }
    private static func date(_ any: Any?) -> Date? {
        guard let t = any as? Double, t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }
}

/// Drives the in-process agent for a debuggable Android app: push artifacts,
/// attach via `cmd activity attach-agent` (no root), `adb forward` the agent's
/// localabstract socket, and stream captured transactions to `onTransaction`.
final class AgentController: @unchecked Sendable {
    private let adbURL: URL
    private let serial: String
    private let package: String
    private let soPath: URL
    private let bootDexPath: URL
    private let captureDexPath: URL
    private let socketName: String
    private let onTransaction: @Sendable (NetworkTransaction) -> Void
    private let onStatus: @Sendable (String) -> Void

    /// Owns the override server, the `adb reverse` tunnel and the control frames. Nil when
    /// response overrides aren't wired up for this session.
    let divert: AgentDivertCoordinator?
    private let interceptPipeline: InterceptPipeline?
    private var interceptServices: InterceptServices?
    private var interceptTarget: InterceptTarget?

    private var forwardedPort: Int32 = 0
    /// The agent socket. Touched by the reader thread, the control queue and `stop()`, so every
    /// access goes through `fdLock` — a plain `var` here was a data race on three threads.
    private let fdLock = NSLock()
    private var _fd: Int32 = -1
    private var fd: Int32 {
        get { fdLock.lock(); defer { fdLock.unlock() }; return _fd }
        set { fdLock.lock(); _fd = newValue; fdLock.unlock() }
    }
    /// Serialises writes to the agent socket so a control frame can't interleave with another.
    private let controlQueue = DispatchQueue(label: "jaca.agent.control")
    private var readerThread: Thread?
    private var stopped = false
    /// Set once the reader connects to the agent's forwarded socket — i.e. the agent actually
    /// loaded in-process. Drives the "attached but never loaded" diagnostic.
    private var socketConnected = false

    init(adbURL: URL, serial: String, package: String, soPath: URL,
         bootDexPath: URL, captureDexPath: URL,
         onTransaction: @escaping @Sendable (NetworkTransaction) -> Void,
         onStatus: @escaping @Sendable (String) -> Void,
         intercept: InterceptServices? = nil) {
        self.adbURL = adbURL
        self.serial = serial
        self.package = package
        self.soPath = soPath
        self.bootDexPath = bootDexPath
        self.captureDexPath = captureDexPath
        self.socketName = "squeeze_\(UInt32.random(in: 1...0xFFFFFF))"
        self.onTransaction = onTransaction
        self.onStatus = onStatus
        self.interceptPipeline = intercept?.pipeline(for: .agentDivert(package: package),
                                                     deviceID: serial, appID: package)
        let target = InterceptTarget(deviceID: serial, package: package)
        self.divert = intercept.map { services in
            AgentDivertCoordinator(adbPath: adbURL.path, serial: serial, package: package,
                                   onStatus: onStatus,
                                   onStateChange: { services.reportArming(target: target, state: $0) })
        }
        self.divert?.sendControlFrame = { [weak self] frame in self?.writeControlFrame(frame) }
        self.interceptServices = intercept
        self.interceptTarget = target
        intercept?.register(target: target, coordinator: self.divert)
    }

    /// Checks whether `package` is debuggable (run-as succeeds only for debug builds).
    static func isDebuggable(adbURL: URL, serial: String, package: String) async -> Bool {
        let r = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "run-as", package, "true"])
        return r?.exitCode == 0
    }

    func start() {
        stopped = false
        Task { await run() }
    }

    private var tmpDir: String { "/data/local/tmp/squeeze" }
    private var codeCache: String { "/data/data/\(package)/code_cache" }

    private func adb(_ args: [String]) async -> CommandRunner.Result? {
        try? await CommandRunner.run(adbURL, ["-s", serial] + args)
    }

    /// Pushes artifacts + sets up the forward once, starts the auto-reconnecting
    /// reader, then supervises the app's pid: re-attaches whenever the app restarts
    /// (a reinstall kills the old process and launches a new one with a new pid).
    private func run() async {
        await pushArtifacts()
        guard await setupForward() else { onStatus("agent: adb forward failed"); return }
        startReaderLoop()

        // Bring the override server + tunnel up before the app is attached, so the port is
        // stable for the whole session (see AgentDivertCoordinator's note on the re-attach trap).
        if let divert, let interceptPipeline {
            await divert.start(pipeline: interceptPipeline)
            startHeartbeat()
        }

        var lastPid: String?
        var announcedWaiting = false
        while !stopped {
            if let pid = await currentPid() {
                if pid != lastPid {                       // app (re)started → (re)attach
                    lastPid = pid
                    announcedWaiting = false
                    await attachTo(pid: pid)
                }
            } else {
                lastPid = nil
                if !announcedWaiting {
                    onStatus("agent: waiting for \(package) to start…")
                    announcedWaiting = true
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func pushArtifacts() async {
        _ = await adb(["shell", "mkdir", "-p", tmpDir])
        for (src, name) in [(soPath, "libsqueezeagent.so"),
                            (bootDexPath, "squeezeagent-boot.dex"),
                            (captureDexPath, "squeezeagent-capture.dex")] {
            let r = await adb(["push", src.path, "\(tmpDir)/\(name)"])
            if r?.exitCode != 0 { onStatus("agent: failed to push \(name) — \(Self.errText(r))") }
        }
    }

    /// Best stderr/stdout from an adb result for a human-readable error (it's a dev tool).
    private static func errText(_ r: CommandRunner.Result?) -> String {
        let s = ((r?.stderr ?? "") + " " + (r?.stdout ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "exit \(r?.exitCode ?? -1)" : s
    }

    private func currentPid() async -> String? {
        guard let out = await adb(["shell", "pidof", package]) else { return nil }
        // pidof returns "1234 5678\n" — first, fully trimmed (a stray newline would
        // corrupt the attach-agent command).
        let pid = out.stdout
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" })
            .first.map(String.init) ?? ""
        return pid.isEmpty ? nil : pid
    }

    /// Copies artifacts into the (possibly fresh) app's code_cache and attaches the
    /// agent. Called once per new process — a clean reinstall wipes code_cache, so we
    /// re-copy every time rather than assuming it survives.
    private func attachTo(pid: String) async {
        let cc = codeCache
        _ = await adb(["shell", "run-as", package, "rm", "-rf",
                       "code_cache/libsqueezeagent.so", "code_cache/squeezeagent-boot.dex",
                       "code_cache/squeezeagent-capture.dex", "code_cache/squeeze_opt"])
        for file in ["libsqueezeagent.so", "squeezeagent-boot.dex", "squeezeagent-capture.dex"] {
            let r = await adb(["shell", "run-as \(package) sh -c 'cat > \(cc)/\(file)' < \(tmpDir)/\(file)"])
            if r?.exitCode != 0 {
                onStatus("agent: couldn't stage \(file) into \(package) — is it a debuggable build? — \(Self.errText(r))")
                return
            }
        }
        _ = await adb(["shell", "run-as", package, "chmod", "444",
                       "code_cache/squeezeagent-boot.dex", "code_cache/squeezeagent-capture.dex"])  // ART rejects writable dex
        let spec = "\(cc)/libsqueezeagent.so=\(cc)/squeezeagent-boot.dex,\(cc)/squeezeagent-capture.dex,\(socketName)"
        let r = await adb(["shell", "cmd activity attach-agent \(pid) '\(spec)'"])
        // attach-agent can print an error to stdout/stderr and still exit 0, so check both.
        let out = ((r?.stdout ?? "") + (r?.stderr ?? "")).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = out.lowercased()
        if r?.exitCode != 0 || lower.contains("error") || lower.contains("exception") || lower.contains("fail") {
            onStatus("agent: attach-agent failed for pid \(pid) — \(out.isEmpty ? "exit \(r?.exitCode ?? -1)" : out)")
            return
        }
        onStatus("agent: in-process (attached pid \(pid))")
        scheduleAgentLoadCheck(pid: pid)
    }

    /// If the agent's socket never opens after attaching, it failed to load in-process — say so,
    /// with where to look, instead of sitting silently on "attached".
    private func scheduleAgentLoadCheck(pid: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, !self.stopped, !self.socketConnected else { return }
            self.onStatus("agent: attached to pid \(pid) but its in-process socket never opened — it "
                + "likely failed to load. Check `adb logcat | grep -i squeeze`; make sure the app is the "
                + "arm64-v8a build.")
        }
    }

    /// Feeds the agent's dead-man switch. If Jaca dies, these stop, and the agent disarms itself
    /// on its own — which is why a SIGKILL can't leave the user's app pointed at a dead tunnel.
    private func startHeartbeat() {
        Task { [weak self] in
            while let self, !self.stopped {
                try? await Task.sleep(for: .seconds(5))
                guard !self.stopped else { return }
                self.divert?.sendHeartbeat()
            }
        }
    }

    /// Writes one newline-delimited control frame to the agent over the socket it already owns.
    /// Serialised on `controlQueue` so frames can't interleave.
    private func writeControlFrame(_ json: String) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            let socket = self.fd
            guard socket >= 0 else {
                JacaLog.warn("agent", "control frame dropped — socket closed")
                return
            }
            let data = Array((json + "\n").utf8)
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBufferPointer { buffer in
                    // MSG_NOSIGNAL equivalent: SO_NOSIGPIPE is set on connect, so a write to a
                    // closed socket returns EPIPE instead of killing the process.
                    send(socket, buffer.baseAddress! + offset, data.count - offset, 0)
                }
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private func setupForward() async -> Bool {
        guard let fwd = await adb(["forward", "tcp:0", "localabstract:\(socketName)"]),
              let port = Int32(fwd.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        forwardedPort = port
        // Registered so a quit/^C/crash can't strand it in the adb server, where it would outlive
        // Jaca itself. This closes a leak that predates response overrides.
        AdbTunnelCleanup.register(adbPath: adbURL.path, serial: serial, kind: .forward, port: Int(port))
        return true
    }

    private func startReaderLoop() {
        let thread = Thread { [weak self] in self?.readerLoop() }
        thread.name = "squeeze-agent-reader"
        readerThread = thread
        thread.start()
    }

    /// Connects to the forwarded socket and streams; on disconnect (process died or
    /// not yet attached) it retries forever until stopped, so a re-attached app's
    /// fresh agent is picked up automatically.
    private func readerLoop() {
        while !stopped {
            let s = connect(port: forwardedPort)
            if s < 0 { Thread.sleep(forTimeInterval: 0.3); continue }
            // NB: connecting proves nothing — `adb forward` accepts the TCP connection whether or
            // not anything is listening on the device end, so `socketConnected` is set when the
            // first bytes actually arrive (see streamFrom). Setting it here made the
            // "attached but never loaded" diagnostic impossible to trigger.
            fd = s
            _ = streamFrom(fd: s)
            if fd >= 0 { close(fd); fd = -1 }
            if stopped { return }
            // A re-attach re-points the reporter socket, so the endpoint must be re-sent on the
            // next hello rather than assumed to still be in effect.
            divert?.agentDidReconnect()
            Thread.sleep(forTimeInterval: 0.3)   // socket closed → retry / await re-attach
        }
    }

    /// Reads newline-delimited JSON from `s`. Returns true if any bytes arrived.
    private func streamFrom(fd s: Int32) -> Bool {
        var firstData = true
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while !stopped {
            let n = recv(s, &chunk, chunk.count, 0)
            if n <= 0 { break }
            if firstData {
                firstData = false
                socketConnected = true     // real bytes from the agent: it genuinely loaded
                onStatus("agent: in-process (receiving)")
            }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let line = String(data: lineData, encoding: .utf8) {
                    if let txn = AgentTransactionParser.parse(line) {
                        onTransaction(txn)
                    } else if AgentHelloParser.advertisesOverrideSupport(line) {
                        JacaLog.info("agent", "hello with override/1 from \(package)")
                        // Only now does the desktop send an endpoint, so an older agent that
                        // can't read control frames is a no-op rather than a hazard.
                        divert?.agentDidAdvertiseOverrideSupport()
                    }
                }
            }
        }
        return !firstData
    }

    private func connect(port: Int32) -> Int32 {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 { close(s); return -1 }
        // Without this, writing a control frame to a socket the agent already closed raises
        // SIGPIPE and kills Jaca outright.
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return s
    }

    /// Interactive teardown. Stays **asynchronous** on purpose: this runs on the main actor from
    /// the stop button, a source switch and tab close, and a synchronous `adb` call would block
    /// the UI for seconds against a wedged or unplugged device. The synchronous path exists only
    /// for process exit (`AdbTunnelCleanup.revertAll`), where blocking briefly is correct.
    ///
    /// Order matters: disarm the agent and drop the reverse tunnel *before* removing the forward,
    /// so the control channel is still open when the disarm frame is written.
    func stop() {
        stopped = true
        let coordinator = divert
        let p = forwardedPort
        let url = adbURL, serial = serial
        let socket = fd
        let services = interceptServices
        let target = interceptTarget

        // `fd` deliberately stays valid until the coordinator has flushed its disarm frame.
        // Clearing it here (as this used to) made `writeControlFrame` bail on every teardown, so
        // the graceful "stop diverting" message was *always* dropped and the device only ever
        // recovered via the EOF/heartbeat fallbacks.
        Task {
            await coordinator?.stop()                       // divert off, reverse removed, server closed
            self.fd = -1
            if socket >= 0 { close(socket) }
            if p > 0 {
                _ = try? await CommandRunner.run(url, ["-s", serial, "forward", "--remove", "tcp:\(p)"])
                AdbTunnelCleanup.deregister(adbPath: url.path, serial: serial, kind: .forward, port: Int(p))
            }
            // Drop the coordinator so a closed tab stops receiving host-set updates.
            if let target { services?.register(target: target, coordinator: nil) }
        }
    }
}
