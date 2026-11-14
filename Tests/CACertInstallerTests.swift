import XCTest
@testable import Jaca

final class CACertInstallerTests: XCTestCase {
    func testApexInjectionBindsIntoNamespaces() {
        let script = AndroidCACertInstaller.injectionScript(
            hash: "4ed68daa", devCert: "/data/local/tmp/4ed68daa.0", useApex: true)
        XCTAssertTrue(script.contains("mount -t tmpfs tmpfs"))
        XCTAssertTrue(script.contains("chcon u:object_r:system_file:s0"))
        XCTAssertTrue(script.contains("nsenter --mount=/proc/$pid/ns/mnt"))
        XCTAssertTrue(script.contains("pidof zygote zygote64"))
        XCTAssertTrue(script.contains("/data/local/tmp/4ed68daa.0"))
        XCTAssertTrue(script.contains("JACA_INJECT_OK"))
    }

    func testLegacyInjectionSkipsApexBind() {
        let script = AndroidCACertInstaller.injectionScript(
            hash: "abc12345", devCert: "/data/local/tmp/abc12345.0", useApex: false)
        XCTAssertTrue(script.contains("mount -t tmpfs tmpfs"))
        XCTAssertFalse(script.contains("nsenter"))   // no APEX on API < 34
        XCTAssertTrue(script.contains("JACA_INJECT_OK"))
    }

    func testUninstallScriptLazyUnmounts() {
        let apex = AndroidCACertInstaller.uninstallScript(hash: "4ed68daa", useApex: true)
        XCTAssertTrue(apex.contains("umount -l"))
        XCTAssertTrue(apex.contains("nsenter"))
        let legacy = AndroidCACertInstaller.uninstallScript(hash: "abc12345", useApex: false)
        XCTAssertFalse(legacy.contains("nsenter"))
    }

    // MARK: - Script snapshots

    /// The injection script was validated on a live emulator. Any change to its
    /// text must be deliberate, so the whole text is pinned here.
    func testInjectionScriptSnapshotApex() {
        let script = AndroidCACertInstaller.injectionScript(
            hash: "4ed68daa", devCert: "/data/local/tmp/4ed68daa.0", useApex: true)
        let expected = """
        set -e
        APEX=/apex/com.android.conscrypt/cacerts
        SYS=/system/etc/security/cacerts
        CERT=/data/local/tmp/4ed68daa.0
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
        for pid in $(pidof zygote zygote64) $(ps -A -o PID,USER 2>/dev/null | awk '$2 ~ /^u0_a/ {print $1}'); do
          timeout 2 nsenter --mount=/proc/$pid/ns/mnt -- mount --bind "$SYS" "$APEX" 2>/dev/null || true
        done
        rm -rf /data/local/tmp/jaca-cc
        rm -f "$CERT"
        echo JACA_INJECT_OK
        """
        XCTAssertEqual(script, expected)
    }

    func testInjectionScriptSnapshotLegacy() {
        let script = AndroidCACertInstaller.injectionScript(
            hash: "abc12345", devCert: "/data/local/tmp/abc12345.0", useApex: false)
        let expected = """
        set -e
        APEX=/apex/com.android.conscrypt/cacerts
        SYS=/system/etc/security/cacerts
        CERT=/data/local/tmp/abc12345.0
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

        rm -rf /data/local/tmp/jaca-cc
        rm -f "$CERT"
        echo JACA_INJECT_OK
        """
        XCTAssertEqual(script, expected)
    }

    func testVerifyScriptChecksTheZygoteNamespace() {
        let apex = AndroidCACertInstaller.verifyScript(hash: "4ed68daa", useApex: true)
        XCTAssertEqual(apex, """
        Z=$(pidof zygote64 zygote | tr ' ' '\\n' | head -n1)
        [ -n "$Z" ] && nsenter --mount=/proc/$Z/ns/mnt -- ls /apex/com.android.conscrypt/cacerts/4ed68daa.0
        """)
        let legacy = AndroidCACertInstaller.verifyScript(hash: "abc12345", useApex: false)
        XCTAssertTrue(legacy.hasSuffix("-- ls /system/etc/security/cacerts/abc12345.0"))
    }

    // MARK: - Headless rooted install

    private let adb = URL(fileURLWithPath: "/fake/adb")
    private let pem = URL(fileURLWithPath: "/fake/ca.pem")

    private func caps(_ root: RootStatus, sdk: Int = 34) -> AndroidCapabilities {
        AndroidCapabilities(isEmulator: true, sdkInt: sdk, abi: "arm64-v8a", hasScreenLock: false, root: root)
    }

    private func install(_ fake: FakeAdb, caps: AndroidCapabilities,
                         hash: String? = "4ed68daa") async -> HeadlessCAOutcome {
        let env = AndroidCAInstallEnvironment(
            run: { url, args in fake.run(url, args) },
            probe: { _, _ in caps },
            subjectHash: { _ in hash })
        return await AndroidCACertInstaller.installRootedHeadless(
            adbURL: adb, serial: "emulator-5554", caPEM: pem, environment: env)
    }

    func testHeadlessReturnsNotRootedWhenTheProbeFindsNoRoot() async {
        let fake = FakeAdb()
        let outcome = await install(fake, caps: caps(.notRooted))
        XCTAssertEqual(outcome, .notRooted)
        XCTAssertTrue(fake.calls.isEmpty, "a non-rooted device gets no adb command")
    }

    func testHeadlessReturnsNotRootedWhenTheProbeCannotReachTheDevice() async {
        let fake = FakeAdb()
        let outcome = await install(fake, caps: .unknown)
        XCTAssertEqual(outcome, .notRooted)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testHeadlessReturnsNotRootedWhenAdbRootAndSuBothFail() async {
        let fake = FakeAdb()
        fake.adbdRoot = false
        fake.suRoot = false
        let outcome = await install(fake, caps: caps(.rooted))
        XCTAssertEqual(outcome, .notRooted)
        XCTAssertFalse(fake.calls.contains { $0.contains("push") })
    }

    func testHeadlessShortCircuitsWhenTheStoreAlreadyHasTheCA() async {
        let fake = FakeAdb()
        fake.alreadyInstalled = true
        let outcome = await install(fake, caps: caps(.rooted))
        XCTAssertEqual(outcome, .installed)
        XCTAssertFalse(fake.injected, "an installed CA is not injected again")
        XCTAssertFalse(fake.calls.contains { $0.last == "/data/local/tmp/4ed68daa.0" },
                       "the cert is not pushed again")
    }

    func testHeadlessInjectsThenVerifies() async {
        let fake = FakeAdb()
        let outcome = await install(fake, caps: caps(.rooted))
        XCTAssertEqual(outcome, .installed)
        XCTAssertTrue(fake.injected)
        XCTAssertTrue(fake.calls.contains { $0.last == "/data/local/tmp/4ed68daa.0" })
        XCTAssertTrue(fake.injectedScript?.contains("nsenter --mount=/proc/$pid/ns/mnt") == true,
                      "API 34+ binds into the APEX namespaces")
    }

    func testHeadlessLegacyInjectionSkipsApexBind() async {
        let fake = FakeAdb()
        let outcome = await install(fake, caps: caps(.rooted, sdk: 30))
        XCTAssertEqual(outcome, .installed)
        XCTAssertEqual(fake.injectedScript?.contains("nsenter"), false)
    }

    func testHeadlessUsesSuWhenAdbdCannotBeRoot() async {
        let fake = FakeAdb()
        fake.adbdRoot = false
        let outcome = await install(fake, caps: caps(.rooted))
        XCTAssertEqual(outcome, .installed)
        XCTAssertTrue(fake.calls.contains { $0.contains("su") && $0.contains("sh") })
    }

    func testHeadlessFailsWhenTheInjectionFails() async {
        let fake = FakeAdb()
        fake.injectionWorks = false
        let outcome = await install(fake, caps: caps(.rooted))
        XCTAssertEqual(outcome, .failed("Couldn't write to the system trust store."))
    }

    func testHeadlessFailsWhenTheHashCannotBeComputed() async {
        let fake = FakeAdb()
        let outcome = await install(fake, caps: caps(.rooted), hash: nil)
        XCTAssertEqual(outcome, .failed("Couldn't compute the certificate hash (openssl)."))
    }
}

/// A fake `adb` for the rooted install. It reads each pushed root script at
/// push time and answers `sh <script>` from that script's text.
private final class FakeAdb: @unchecked Sendable {
    var adbdRoot = true
    var suRoot = true
    var alreadyInstalled = false
    var injectionWorks = true

    private let lock = NSLock()
    private var _calls: [[String]] = []
    private var scripts: [String: String] = [:]
    private var _injectedScript: String?
    private var _injected = false

    var calls: [[String]] { lock.withLock { _calls } }
    var injected: Bool { lock.withLock { _injected } }
    var injectedScript: String? { lock.withLock { _injectedScript } }

    func run(_ url: URL, _ args: [String]) -> CommandRunner.Result {
        lock.withLock {
            _calls.append(args)
            // Drop "-s <serial>".
            let cmd = Array(args.dropFirst(2))
            func ok(_ out: String = "") -> CommandRunner.Result { .init(exitCode: 0, stdout: out, stderr: "") }
            switch cmd.first {
            case "root":
                return adbdRoot ? ok("adbd is already running as root\n")
                    : .init(exitCode: 1, stdout: "", stderr: "adbd cannot run as root in production builds\n")
            case "wait-for-device":
                return ok()
            case "push":
                let local = cmd[1], remote = cmd[2]
                if local.hasSuffix("-script.sh") {
                    scripts[remote] = (try? String(contentsOfFile: local, encoding: .utf8)) ?? ""
                }
                return ok()
            case "shell":
                let rest = Array(cmd.dropFirst())
                if rest == ["id"] { return ok(adbdRoot ? "uid=0(root)" : "uid=2000(shell)") }
                if rest == ["su", "0", "id"] { return suRoot ? ok("uid=0(root)") : .init(exitCode: 1, stdout: "", stderr: "su: not found") }
                if rest.first == "rm" { return ok() }
                guard let dev = rest.last, let script = scripts[dev] else { return ok() }
                if script.contains("JACA_INJECT_OK") {
                    _injectedScript = script
                    guard injectionWorks else { return .init(exitCode: 1, stdout: "", stderr: "mount: denied") }
                    _injected = true
                    return ok("JACA_INJECT_OK\n")
                }
                if script.contains("-- ls ") {
                    return (alreadyInstalled || _injected) ? ok("/apex/com.android.conscrypt/cacerts/4ed68daa.0\n")
                        : .init(exitCode: 1, stdout: "", stderr: "No such file")
                }
                return ok()
            default:
                return ok()
            }
        }
    }
}

