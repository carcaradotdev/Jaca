import Foundation

/// Installs Jaca's proxy root CA onto an Android device so apps trust the MITM
/// proxy, picking the best strategy from the device's capabilities and reporting
/// **step-by-step progress** for the UI.
///
/// - Rooted / emulator → installs into the **system** trust store with no
///   on-device interaction. On API 34+ the conscrypt APEX is the authoritative
///   store, so we mount a tmpfs over `/system/etc/security/cacerts` and bind it
///   into each process's APEX namespace via `nsenter` (the technique validated
///   against the live emulator). This is non-persistent (cleared on reboot), so
///   it's safe to re-run. Only a user action starts it, never capture start.
/// - Not rooted → pushes the cert and opens the system CA-install dialog straight
///   to the confirm screen (via a `content://` VIEW intent), then waits for the
///   user to finish, auto-detecting completion in the background.
///
/// Pure `adb`/`Process` work, mirroring `AgentController`. Owns no proxy state;
/// the caller clears the device proxy as part of cancel/teardown.
@MainActor
@Observable
final class AndroidCACertInstaller {
    enum Phase: Equatable {
        case idle
        case choosingMode     // non-rooted: user picks Auto vs Manual
        case running
        case awaitingUser     // non-rooted: waiting on the user (PIN / install)
        case succeeded
        case cancelled
        case failed(String)
    }

    enum StepState: Equatable { case pending, active, done, failed, skipped }

    struct Step: Identifiable, Equatable {
        let id: String
        let title: String
        var detail: String?
        var state: StepState
    }

    enum Mode { case auto, manual }

    private(set) var phase: Phase = .idle
    private(set) var steps: [Step] = []
    /// True when we can install silently into the system store (rooted/emulator).
    let rootMode: Bool
    /// Which non-rooted path the user picked (drives the in-sheet tutorial video).
    private(set) var chosenMode: Mode?

    private let adbURL: URL
    private let serial: String
    private let caPEM: URL
    private let capabilities: AndroidCapabilities
    private var task: Task<Void, Never>?
    /// Whether root shell commands must be wrapped in `su 0` (Magisk) vs run
    /// directly because adbd itself is root. Set during `acquireRoot`.
    private var rootViaSu = false
    /// Set once the install is verified, so `cleanup()` knows whether to bother.
    private var hashName: String?
    /// Flipped by the proxy pipeline when it sees the first intercepted HTTPS
    /// request — the ground-truth signal that the (user-store) CA is trusted.
    private var interceptionConfirmed = false

    init(adbURL: URL, serial: String, caPEM: URL, capabilities: AndroidCapabilities) {
        self.adbURL = adbURL
        self.serial = serial
        self.caPEM = caPEM
        self.capabilities = capabilities
        self.rootMode = capabilities.root == .rooted
        if rootMode { self.steps = Self.make(Self.rootSteps) }
    }

    private static let rootSteps: [(String, String)] = [
        ("root", "Acquire root access"),
        ("prepare", "Prepare certificate"),
        ("install", "Install into system trust store"),
        ("verify", "Verify trust"),
    ]
    /// Manual mode: the user installs it themselves with on-device guidance.
    private static let manualSteps: [(String, String)] = [
        ("push", "Copy certificate to the device"),
        ("open", "Open the on-device guide"),
        ("trust", "Install & trust it in Settings"),
        ("verify", "Confirm HTTPS is decrypting"),
    ]
    /// Auto mode: Jaca taps through Settings, pausing only for the PIN/biometric.
    private static let autoSteps: [(String, String)] = [
        ("push", "Copy certificate to the device"),
        ("navigate", "Open the CA install screen"),
        ("auth", "Authenticate on the device"),
        ("pick", "Select & name the certificate"),
        ("verify", "Confirm HTTPS is decrypting"),
    ]
    private static func make(_ defs: [(String, String)]) -> [Step] {
        defs.map { Step(id: $0.0, title: $0.1, detail: nil, state: .pending) }
    }

    // MARK: - Lifecycle

    func start() {
        guard phase == .idle else { return }
        if rootMode {
            phase = .running
            task = Task { await runRooted() }
        } else {
            // Non-rooted: let the user pick Auto vs Manual first.
            phase = .choosingMode
        }
    }

    /// Auto mode: Jaca drives Settings to the install screen, pausing for the PIN.
    func chooseAuto() {
        guard phase == .choosingMode else { return }
        chosenMode = .auto
        steps = Self.make(Self.autoSteps)
        phase = .running
        task = Task { await runUserAuto() }
    }

    /// Manual mode: on-device guide (video + Open-settings button); user installs it.
    func chooseManual() {
        guard phase == .choosingMode else { return }
        chosenMode = .manual
        steps = Self.make(Self.manualSteps)
        phase = .running
        task = Task { await runUserManual() }
    }

    /// User-initiated cancel, or teardown. Removes pushed files and best-effort
    /// unmounts the system-store overlay. The caller clears the device proxy.
    func cancel() {
        task?.cancel()
        if phase != .succeeded { phase = .cancelled }
        let hash = hashName
        Task { await cleanup(hash: hash) }
    }

    /// Called by the proxy pipeline on the first successfully intercepted HTTPS
    /// transaction — confirms the (user-store) CA is actually trusted.
    func noteInterceptionConfirmed() { interceptionConfirmed = true }

    // MARK: - Rooted (system store)

    private func runRooted() async {
        let result = await Self.runRootedInstall(
            adbURL: adbURL, serial: serial, caPEM: caPEM,
            knownCapabilities: capabilities, environment: .live, checkCancellation: true
        ) { [weak self] event in
            guard let self else { return }
            switch event {
            case .began(let step): self.setState(step.rawValue, .active)
            case .finished(let step): self.setState(step.rawValue, .done)
            case .skipped(let step): self.setState(step.rawValue, .skipped)
            case .rootViaSu(let viaSu): self.rootViaSu = viaSu
            case .hash(let hash):
                self.hashName = "\(hash).0"
                self.detail(HeadlessCAStep.prepare.rawValue, "\(hash).0")
            }
        }
        // nil means the task was cancelled; `cancel()` already set the phase.
        guard let result, !Task.isCancelled, phase != .cancelled else { return }
        let active = steps.first { $0.state == .active }?.id ?? HeadlessCAStep.root.rawValue
        switch result {
        case .installed: phase = .succeeded
        case .notRooted: fail(active, "Couldn't get root on this device.")
        case .failed(let message): fail(active, message)
        }
    }

    // MARK: - Non-rooted: manual (user installs, we guide on-device)

    private func runUserManual() async {
        setState("push", .active)
        let devCert = "/storage/emulated/0/Download/JacaProxyCA.crt"
        hashName = "JacaProxyCA.crt"
        guard await Self.push(caPEM.path, to: devCert, adbURL: adbURL, serial: serial, environment: .live) else {
            fail("push", "Couldn't copy the certificate to the device.")
            return
        }
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "am", "broadcast",
            "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", "file://\(devCert)"])
        setState("push", .done)
        if Task.isCancelled { return }

        // On-device guide (companion app: tutorial video + an "Open security settings"
        // button), so the steps are where the user is looking. Falls back to a plain
        // Settings deep-link if the helper APK isn't bundled.
        setState("open", .active)
        if !capabilities.hasScreenLock {
            detail("open", "Set a screen lock on the device first — Android requires one to install a CA.")
        }
        if !(await OnDeviceGuide.show(adbURL: adbURL, serial: serial)) {
            await openSecuritySettings()
        }
        setState("open", .done)

        setState("trust", .active)
        detail("trust", "On the device: More security settings → Install from device storage → CA certificate → JacaProxyCA, then confirm with your PIN.")
        phase = .awaitingUser
        guard await awaitInterception() else {
            if Task.isCancelled || phase == .cancelled { return }
            fail("trust", "No decrypted HTTPS seen yet. Finish the install on the device, then open any app to confirm.")
            return
        }
        setState("trust", .done)
        setState("verify", .active); setState("verify", .done)
        phase = .succeeded
    }

    // MARK: - Non-rooted: auto (Jaca drives Settings; user only does the PIN)

    private func runUserAuto() async {
        setState("push", .active)
        let devCert = "/storage/emulated/0/Download/JacaProxyCA.crt"
        hashName = "JacaProxyCA.crt"
        guard await Self.push(caPEM.path, to: devCert, adbURL: adbURL, serial: serial, environment: .live) else {
            fail("push", "Couldn't copy the certificate to the device.")
            return
        }
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "am", "broadcast",
            "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE", "-d", "file://\(devCert)"])
        setState("push", .done)
        if Task.isCancelled { return }

        let driver = UiAutomatorDriver(adbURL: adbURL, serial: serial)

        // Drive Settings → CA-install warning. Falls back to guidance if the OEM
        // layout/locale doesn't match, rather than failing.
        setState("navigate", .active)
        if !capabilities.hasScreenLock {
            detail("navigate", "Set a screen lock on the device first — Android requires one to install a CA.")
        }
        await driver.openSecuritySettings()
        try? await Task.sleep(for: .seconds(1))
        let reached = await driveToInstallWarning(driver)
        if Task.isCancelled || phase == .cancelled { return }
        if !reached {
            detail("navigate", "Couldn't auto-navigate this device — on it: More security settings → Install from device storage → CA certificate → JacaProxyCA.")
        }
        setState("navigate", reached ? .done : .skipped)

        // Biometric / PIN — only the user can pass this. Wait for the file picker.
        setState("auth", .active)
        detail("auth", "Confirm with your fingerprint or PIN on the device.")
        phase = .awaitingUser
        let pickerReady = await driver.waitFor(text: ["JacaProxyCA", "Download"], timeoutSeconds: 120)
        if Task.isCancelled || phase == .cancelled { return }
        setState("auth", .done)

        // Auto-pick the cert + confirm the name (best-effort).
        setState("pick", .active)
        phase = .running
        if pickerReady {
            _ = await driver.tapText(["JacaProxyCA"], scrolls: 3)
            try? await Task.sleep(for: .seconds(1))
            if !(await driver.tapId("android:id/button1")) { _ = await driver.tapText(["OK"], scrolls: 0) }
        } else {
            detail("pick", "Pick JacaProxyCA from Downloads on the device.")
        }
        setState("pick", .done)

        setState("verify", .active)
        phase = .awaitingUser
        guard await awaitInterception() else {
            if Task.isCancelled || phase == .cancelled { return }
            fail("verify", "No decrypted HTTPS seen yet. If it's installed, open any app to confirm.")
            return
        }
        setState("verify", .done)
        phase = .succeeded
    }

    /// Walks Settings → (More security settings) → Install from device storage →
    /// CA certificate → "Install anyway", by localized text + stable ids.
    private func driveToInstallWarning(_ driver: UiAutomatorDriver) async -> Bool {
        let moreSecurity = ["More security settings", "Mais configurações de segurança",
                            "Other security settings", "Outras configurações de segurança"]
        let installFromStorage = ["Install from device storage", "Install from storage",
                                  "Instalar do armazen", "Instalar do armazenamento"]
        let caCertificate = ["CA certificate", "Certificado CA"]
        _ = await driver.tapText(moreSecurity, scrolls: 4)
        try? await Task.sleep(for: .milliseconds(700))
        guard await driver.tapText(installFromStorage, scrolls: 6) else { return false }
        try? await Task.sleep(for: .milliseconds(700))
        guard await driver.tapText(caCertificate, scrolls: 3) else { return false }
        try? await Task.sleep(for: .milliseconds(800))
        if await driver.tapId("com.android.settings:id/button_positive") { return true }
        return await driver.tapText(["Install anyway", "Instalar mesmo assim"], scrolls: 0)
    }

    /// Opens the device's Security settings (the only place a non-rooted CA install
    /// can complete). Public so the sheet can re-open it on demand.
    func openSecuritySettings() async {
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "am", "start",
            "-a", "android.settings.SECURITY_SETTINGS"])
    }

    /// Opens a test HTTPS page on the device so the proxy gets a request to decrypt.
    /// If the CA is trusted it succeeds and the passive detector confirms — a one-tap
    /// way to verify without making the user go browse something.
    func triggerVerifyRequest() async {
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "am", "start",
            "-a", "android.intent.action.VIEW", "-d", "https://example.com"])
    }

    /// Polls for the ground-truth trust signal: the first HTTPS request decrypted
    /// through the proxy (`noteInterceptionConfirmed`). ~20 min budget.
    private func awaitInterception() async -> Bool {
        for _ in 0..<600 {
            if Task.isCancelled || phase == .cancelled { return false }
            if interceptionConfirmed { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    // MARK: - Cleanup

    private func cleanup(hash: String?) async {
        // Remove anything we pushed.
        _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "rm", "-f",
            "/storage/emulated/0/Download/JacaProxyCA.crt"])
        if let hash, rootMode {
            _ = try? await CommandRunner.run(adbURL, ["-s", serial, "shell", "rm", "-f",
                "/data/local/tmp/\(hash)"])
            // Best-effort unmount of the system-store overlay (mounts are also
            // non-persistent, so this is belt-and-suspenders).
            let bare = hash.replacingOccurrences(of: ".0", with: "")
            _ = await runRootScript(Self.uninstallScript(hash: bare, useApex: capabilities.usesApexCACerts))
        }
    }

    // MARK: - adb helpers

    @discardableResult
    private func runRootScript(_ script: String) async -> CommandRunner.Result? {
        await Self.runRootScript(script, adbURL: adbURL, serial: serial, viaSu: rootViaSu, environment: .live)
    }

    // MARK: - Progress mutation

    private func setState(_ id: String, _ state: StepState) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].state = state
    }
    private func detail(_ id: String, _ text: String) {
        guard let idx = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[idx].detail = text
    }
    private func fail(_ id: String, _ message: String) {
        setState(id, .failed)
        phase = .failed(message)
    }

    // MARK: - Static: headless install

    /// Installs the CA into the system trust store with no UI and no step
    /// progress. The TUI, the CLI and the GUI's rooted branch use this path.
    /// It does nothing when the CA is already in the store. Only a user action
    /// calls it; capture start never does.
    nonisolated static func installRootedHeadless(
        adbURL: URL, serial: String, caPEM: URL,
        environment: AndroidCAInstallEnvironment = .live
    ) async -> HeadlessCAOutcome {
        let result = await runRootedInstall(
            adbURL: adbURL, serial: serial, caPEM: caPEM, knownCapabilities: nil,
            environment: environment, checkCancellation: false, progress: { _ in })
        // `checkCancellation: false` never returns nil; treat nil as "no change made".
        return result ?? .notRooted
    }

    /// Copies the CA to the device's Download folder so the user can install it
    /// from Settings. Returns false when the push fails.
    nonisolated static func pushForManualInstall(adbURL: URL, serial: String, caPEM: URL) async -> Bool {
        await ProxyConfigurator.pushCACertToAndroid(adbURL: adbURL, serial: serial, caPEM: caPEM)
    }

    /// The rooted install, shared by the headless call and the step UI.
    /// - `knownCapabilities`: skip the probe when the caller already has them.
    /// - `checkCancellation`: return nil when the task is cancelled between steps.
    /// - `progress`: step events for the UI.
    /// The failure messages are the step UI's existing copy.
    nonisolated static func runRootedInstall(
        adbURL: URL, serial: String, caPEM: URL,
        knownCapabilities: AndroidCapabilities?,
        environment env: AndroidCAInstallEnvironment,
        checkCancellation: Bool,
        progress: @escaping @MainActor @Sendable (HeadlessCAEvent) -> Void
    ) async -> HeadlessCAOutcome? {
        func cancelled() -> Bool { checkCancellation && Task.isCancelled }

        // 1. Root.
        await progress(.began(.root))
        var caps = knownCapabilities
        if caps == nil { caps = await env.probe(adbURL, serial) }
        guard let caps, caps.root == .rooted else { return .notRooted }
        guard let viaSu = await acquireRoot(adbURL: adbURL, serial: serial, environment: env) else {
            return .notRooted
        }
        await progress(.rootViaSu(viaSu))
        await progress(.finished(.root))
        if cancelled() { return nil }

        // 2. Prepare: compute the Android subject-hash filename.
        await progress(.began(.prepare))
        guard let hash = await env.subjectHash(caPEM) else {
            return .failed("Couldn't compute the certificate hash (openssl).")
        }
        await progress(.hash(hash))

        // Already trusted: change nothing.
        if await verifySystemStore(hash: hash, useApex: caps.usesApexCACerts,
                                   adbURL: adbURL, serial: serial, viaSu: viaSu, environment: env) {
            await progress(.finished(.prepare))
            await progress(.skipped(.install))
            await progress(.began(.verify))
            await progress(.finished(.verify))
            return .installed
        }
        if cancelled() { return nil }

        let devCert = "/data/local/tmp/\(hash).0"
        guard await push(caPEM.path, to: devCert, adbURL: adbURL, serial: serial, environment: env) else {
            return .failed("Couldn't copy the certificate to the device.")
        }
        await progress(.finished(.prepare))
        if cancelled() { return nil }

        // 3. Inject into the system / APEX store.
        await progress(.began(.install))
        let script = injectionScript(hash: hash, devCert: devCert, useApex: caps.usesApexCACerts)
        let injected = await runRootScript(script, adbURL: adbURL, serial: serial, viaSu: viaSu, environment: env)
        guard injected?.stdout.contains("JACA_INJECT_OK") == true else {
            return .failed("Couldn't write to the system trust store.")
        }
        await progress(.finished(.install))
        if cancelled() { return nil }

        // 4. Verify the cert is visible in the live trust store.
        await progress(.began(.verify))
        guard await verifySystemStore(hash: hash, useApex: caps.usesApexCACerts,
                                      adbURL: adbURL, serial: serial, viaSu: viaSu, environment: env) else {
            return .failed("The certificate didn't appear in the trust store.")
        }
        await progress(.finished(.verify))
        return .installed
    }

    /// `adb root` (userdebug/emulator) or fall back to Magisk `su`. Returns nil
    /// without root, otherwise whether root commands need the `su 0` wrapper.
    nonisolated static func acquireRoot(adbURL: URL, serial: String,
                                        environment env: AndroidCAInstallEnvironment) async -> Bool? {
        let r = try? await env.run(adbURL, ["-s", serial, "root"])
        let out = ((r?.stdout ?? "") + (r?.stderr ?? "")).lowercased()
        if !(out.contains("cannot run as root") || out.contains("production builds")) {
            // "restarting adbd as root" / "already running as root" — wait for adbd,
            // then confirm we actually have root.
            _ = try? await env.run(adbURL, ["-s", serial, "wait-for-device"])
            let id = try? await env.run(adbURL, ["-s", serial, "shell", "id"])
            if id?.stdout.contains("uid=0") == true { return false }
        }
        // adbd refused or isn't root — fall back to Magisk `su`.
        let su = try? await env.run(adbURL, ["-s", serial, "shell", "su", "0", "id"])
        return su?.stdout.contains("uid=0") == true ? true : nil
    }

    /// Verifies in an **app's** mount namespace (zygote), which is what newly
    /// launched apps inherit — NOT adbd's namespace, where we deliberately don't
    /// bind the APEX overlay. (Checking via a plain `adb shell` would always miss
    /// it on API 34+.)
    nonisolated static func verifySystemStore(hash: String, useApex: Bool, adbURL: URL, serial: String,
                                              viaSu: Bool, environment env: AndroidCAInstallEnvironment) async -> Bool {
        let r = await runRootScript(verifyScript(hash: hash, useApex: useApex),
                                    adbURL: adbURL, serial: serial, viaSu: viaSu, environment: env)
        return r?.stdout.contains("\(hash).0") ?? false
    }

    nonisolated static func verifyScript(hash: String, useApex: Bool) -> String {
        let path = useApex
            ? "/apex/com.android.conscrypt/cacerts/\(hash).0"
            : "/system/etc/security/cacerts/\(hash).0"
        return """
        Z=$(pidof zygote64 zygote | tr ' ' '\\n' | head -n1)
        [ -n "$Z" ] && nsenter --mount=/proc/$Z/ns/mnt -- ls \(path)
        """
    }

    nonisolated static func push(_ local: String, to remote: String, adbURL: URL, serial: String,
                                 environment env: AndroidCAInstallEnvironment) async -> Bool {
        let r = try? await env.run(adbURL, ["-s", serial, "push", local, remote])
        return r?.exitCode == 0
    }

    /// Runs `script` as root by pushing it to the device and executing the **file**
    /// — not `sh -c "<inline>"`, which adb's shell re-splits on spaces and mangles
    /// (`$()`, pipes, `--` all break). Validated: only the file form runs reliably.
    nonisolated static func runRootScript(_ script: String, adbURL: URL, serial: String, viaSu: Bool,
                                          environment env: AndroidCAInstallEnvironment) async -> CommandRunner.Result? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-script.sh")
        do { try script.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        let dev = "/data/local/tmp/jaca-\(UUID().uuidString).sh"
        guard await push(url.path, to: dev, adbURL: adbURL, serial: serial, environment: env) else { return nil }
        let invoke = viaSu ? ["shell", "su", "0", "sh", dev] : ["shell", "sh", dev]
        let r = try? await env.run(adbURL, ["-s", serial] + invoke)
        _ = try? await env.run(adbURL, ["-s", serial, "shell", "rm", "-f", dev])
        return r
    }

    // MARK: - Static: hash + scripts

    /// Computes Android's `subject_hash_old` (the `<hash>.0` filename a CA must use
    /// in the trust store) via the system openssl.
    nonisolated static func subjectHashOld(pem: URL) async -> String? {
        let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
        guard FileManager.default.isExecutableFile(atPath: openssl.path) else { return nil }
        let r = try? await CommandRunner.run(openssl,
            ["x509", "-inform", "PEM", "-subject_hash_old", "-noout", "-in", pem.path])
        let hash = (r?.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // An 8-hex-digit hash.
        let valid = hash.count == 8 && hash.allSatisfy { $0.isHexDigit }
        return valid ? hash : nil
    }

    /// The validated root injection: tmpfs over the legacy store, repopulate +
    /// add our cert, fix perms/labels, and (API 34+) bind into the conscrypt APEX
    /// inside zygote + running-app namespaces so new and existing apps trust it.
    nonisolated static func injectionScript(hash: String, devCert: String, useApex: Bool) -> String {
        // `|| true` keeps `set -e` from aborting when a bind fails (a pid exited,
        // or `timeout` fired) — partial namespace coverage is expected and fine.
        let apexBind = useApex ? """
        for pid in $(pidof zygote zygote64) $(ps -A -o PID,USER 2>/dev/null | awk '$2 ~ /^u0_a/ {print $1}'); do
          timeout 2 nsenter --mount=/proc/$pid/ns/mnt -- mount --bind "$SYS" "$APEX" 2>/dev/null || true
        done
        """ : ""
        return """
        set -e
        APEX=/apex/com.android.conscrypt/cacerts
        SYS=/system/etc/security/cacerts
        CERT=\(devCert)
        rm -rf /data/local/tmp/jaca-cc
        mkdir -p -m 700 /data/local/tmp/jaca-cc
        cp "$SYS"/* /data/local/tmp/jaca-cc/ 2>/dev/null || true
        [ -d "$APEX" ] && cp "$APEX"/* /data/local/tmp/jaca-cc/ 2>/dev/null || true
        mount -t tmpfs tmpfs "$SYS"
        cp /data/local/tmp/jaca-cc/* "$SYS"/ 2>/dev/null || true
        cp "$CERT" "$SYS"/
        chown root:root "$SYS"/* 2>/dev/null || true
        chmod 644 "$SYS"/* 2>/dev/null || true
        chcon u:object_r:system_file:s0 "$SYS"/* 2>/dev/null || true
        \(apexBind)
        rm -rf /data/local/tmp/jaca-cc
        rm -f "$CERT"
        echo JACA_INJECT_OK
        """
    }

    /// Best-effort teardown of the overlay (mounts are non-persistent anyway).
    nonisolated static func uninstallScript(hash: String, useApex: Bool) -> String {
        let apexUnbind = useApex ? """
        for pid in $(pidof zygote zygote64) $(ps -A -o PID,USER 2>/dev/null | awk '$2 ~ /^u0_a/ {print $1}'); do
          timeout 2 nsenter --mount=/proc/$pid/ns/mnt -- umount -l "$APEX" 2>/dev/null
        done
        """ : ""
        return """
        APEX=/apex/com.android.conscrypt/cacerts
        SYS=/system/etc/security/cacerts
        \(apexUnbind)
        timeout 2 umount -l "$SYS" 2>/dev/null || true
        echo JACA_UNINSTALL_OK
        """
    }
}

/// The result of a headless rooted CA install.
enum HeadlessCAOutcome: Sendable, Equatable {
    /// The CA is in the system trust store (newly, or it already was).
    case installed
    /// Jaca can't get root on this device; use the manual install instead.
    case notRooted
    /// Root worked but a step failed. The message is the step UI's copy.
    case failed(String)
}

/// The steps of the rooted install. The raw values are the step UI's ids.
enum HeadlessCAStep: String, Sendable {
    case root, prepare, install, verify
}

/// Progress from `AndroidCACertInstaller.runRootedInstall`, for the step UI.
enum HeadlessCAEvent: Sendable {
    case began(HeadlessCAStep)
    case finished(HeadlessCAStep)
    case skipped(HeadlessCAStep)
    case rootViaSu(Bool)
    case hash(String)
}

/// The commands the rooted install runs. Tests swap these for fakes so they
/// never touch a device or call openssl.
struct AndroidCAInstallEnvironment: Sendable {
    var run: @Sendable (URL, [String]) async throws -> CommandRunner.Result
    var probe: @Sendable (URL, String) async -> AndroidCapabilities
    var subjectHash: @Sendable (URL) async -> String?

    static let live = AndroidCAInstallEnvironment(
        run: { try await CommandRunner.run($0, $1) },
        probe: { await AndroidCapabilityProbe.probe(adbURL: $0, serial: $1) },
        subjectHash: { await AndroidCACertInstaller.subjectHashOld(pem: $0) }
    )
}
