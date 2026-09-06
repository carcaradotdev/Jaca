import Foundation

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
    let divert: DivertCoordinator?
    private let interceptPipeline: InterceptPipeline?
    private let interceptServices: InterceptServices?
    private let interceptTarget: InterceptTarget?

    /// The socket to the agent, including its lock, `SO_NOSIGPIPE` and the line framing.
    private let channel: AgentLineChannel
    /// The channel has to exist before `self` does — the coordinator takes it as its writer — so
    /// its callbacks reach back through this box, filled in at the end of `init`.
    private let weakSelf = WeakController()

    private var forwardedPort: Int32 = 0
    private var stopped = false
    /// Set once the agent's first bytes arrive — i.e. it actually loaded in-process. Drives the
    /// "attached but never loaded" diagnostic.
    private let socketConnected = AtomicFlag()

    init(adbURL: URL, serial: String, package: String, soPath: URL,
         bootDexPath: URL, captureDexPath: URL,
         onTransaction: @escaping @Sendable (NetworkTransaction) -> Void,
         onStatus: @escaping @Sendable (String) -> Void,
         capabilities: InterceptCapabilities,
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
        let box = self.weakSelf
        let channel = AgentLineChannel(name: "android-\(package)", callbacks: .init(
            onLine: { line in box.controller?.handle(line: line) },
            onFirstBytes: { box.controller?.noteAgentLoaded() },
            // On *disconnect*: the re-arm rides the next hello or heartbeat, so a re-attached
            // agent is never spoken to before it has said anything.
            onDisconnected: { box.controller?.divert?.agentDidReconnect() }))
        self.channel = channel
        let target = InterceptTarget(deviceID: serial, package: package)
        self.divert = intercept.map { services in
            DivertCoordinator(transport: .agentDivert(package: package),
                              deviceID: serial, appID: package,
                              capabilities: capabilities,
                              tunnel: AdbReverseTunnel(adbPath: adbURL.path, serial: serial),
                              writer: channel,
                              onStateChange: { services.reportArming(target: target, coordinator: $0, state: $1) })
        }
        self.interceptServices = intercept
        self.interceptTarget = target
        if let divert = self.divert { intercept?.register(target: target, coordinator: divert) }
        box.controller = self
    }

    /// One agent line, routed. Both controllers classify through `AgentFrame`, so their readers
    /// can't drift apart.
    private func handle(line: String) {
        switch AgentFrame.classify(line) {
        case .transaction(let txn):
            onTransaction(txn)
        case .hello(let supportsOverride):
            guard supportsOverride else {
                // Alive but predating overrides — reporting it turns an eternal "arming…" into
                // a sentence that names the fix.
                divert?.agentDidAdvertiseWithoutOverrideSupport()
                return
            }
            JacaLog.info("agent", "hello with override/1 from \(package)")
            // Only now does the desktop send an endpoint, so an older agent that can't read
            // control frames is a no-op rather than a hazard.
            divert?.agentDidAdvertiseOverrideSupport()
        case .unrecognised:
            break
        }
    }

    private func noteAgentLoaded() {
        socketConnected.set()
        onStatus("agent: in-process (receiving)")
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
        // `stop()` can land inside any of these awaits — pushing ~15 MB of artifacts takes
        // seconds over USB — so each is followed by a re-check. Without them the teardown
        // completes first and this function brings everything back up behind it: a dial thread
        // retrying forever, an override server nobody closes, an `adb reverse` nobody removes.
        await pushArtifacts()
        guard !stopped else { return }

        guard await setupForward() else { onStatus("agent: adb forward failed"); return }
        // `stop()` already captured `forwardedPort` as 0, so nothing else will ever remove this one.
        guard !stopped else { await removeForward(); return }

        channel.dial(port: forwardedPort)

        // Up before the app is attached, so the port is stable for the whole session (see
        // `DivertCoordinator`).
        if let divert, let interceptPipeline {
            await divert.start(pipeline: interceptPipeline)
        }
        guard !stopped else { return }

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
            guard let self, !self.stopped, !self.socketConnected.isSet else { return }
            self.onStatus("agent: attached to pid \(pid) but its in-process socket never opened — it "
                + "likely failed to load. Check `adb logcat | grep -i squeeze`; make sure the app is the "
                + "arm64-v8a build.")
        }
    }

    private func setupForward() async -> Bool {
        guard let fwd = await adb(["forward", "tcp:0", "localabstract:\(socketName)"]),
              let port = Int32(fwd.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        forwardedPort = port
        // Registered so a quit/^C/crash can't strand it in the adb server, where it would
        // outlive Jaca itself.
        AdbTunnelCleanup.register(adbPath: adbURL.path, serial: serial, kind: .forward, port: Int(port))
        return true
    }

    /// Interactive teardown, **asynchronous** on purpose: it runs on the main actor, where a
    /// synchronous `adb` call would block the UI for seconds against a wedged device. The
    /// synchronous path exists only for process exit (`AdbTunnelCleanup.revertAll`).
    ///
    /// Order matters: disarm and drop the reverse tunnel *before* removing the forward, so the
    /// control channel is still open when the disarm frame is written.
    func stop() {
        stopped = true
        let coordinator = divert
        let p = forwardedPort
        let url = adbURL, serial = serial
        let services = interceptServices
        let target = interceptTarget

        // Stop reconnecting, but leave the live fd open so the disarm frame still lands. Closing
        // it here makes every teardown write bail, leaving the device to recover only via the
        // EOF/heartbeat fallbacks.
        // Synchronous: a restart builds the replacement in the same main-actor run, so a
        // still-live coordinator would leave the target permanently unregistered.
        coordinator?.beginStop()

        channel.stopAccepting()
        Task {
            await coordinator?.stop()                       // divert off, reverse removed, server closed
            await self.channel.flush()                      // the disarm frame has reached send(2)
            self.channel.close()
            await Self.removeForward(port: p, adbURL: url, serial: serial)
            // Drop the coordinator so a closed tab stops receiving host-set updates.
            if let target, let coordinator {
                services?.deregister(target: target, coordinator: coordinator)
            }
        }
    }

    /// Drops the forward this controller opened. Shared with `run()`'s bail-out: a forward
    /// created after `stop()` captured the port is invisible to the teardown.
    private func removeForward() async {
        let p = forwardedPort
        forwardedPort = 0
        await Self.removeForward(port: p, adbURL: adbURL, serial: serial)
    }

    private static func removeForward(port: Int32, adbURL: URL, serial: String) async {
        guard port > 0 else { return }
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "forward", "--remove", "tcp:\(port)"])
        AdbTunnelCleanup.deregister(adbPath: adbURL.path, serial: serial, kind: .forward, port: Int(port))
    }
}

/// Lets `AgentLineChannel`'s callbacks reach the controller. The channel is constructed before
/// `self` exists, so they can't capture it directly.
private final class WeakController: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: AgentController?
    var controller: AgentController? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// A one-way flag set from the reader thread and read from a `Task`.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
