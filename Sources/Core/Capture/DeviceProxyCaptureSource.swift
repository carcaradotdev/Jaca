import Foundation

/// Captures every app on an Android device (emulator or USB) through a MITM proxy on this Mac.
///
/// The proxy listens on `127.0.0.1:P`. `adb reverse tcp:P tcp:P` makes that port the device's
/// own loopback, and the device's global `http_proxy` points at it. So one route serves an
/// emulator and a USB phone, and the proxy never listens on the LAN.
///
/// Start order: ledger entry, then `adb reverse`, then `settings put`. The ledger entry comes
/// first, so a SIGKILL after the device changed always leaves a record to repair it from.
/// Stop order: restore or clear the proxy, remove the reverse, stop the server, remove the
/// ledger entry. The stop runs as one task that `DeviceReleaseGate` tracks, so the next capture
/// on the device arms only after it.
///
/// The source never installs the CA. That is a user action in the setup sheet, the TUI or the
/// CLI.
@MainActor
final class DeviceProxyCaptureSource: CaptureSource {
    private let device: Device
    private let adbURL: URL?
    private let ca: CertificateAuthority?
    private let intercept: InterceptServices?
    private let environment: DeviceProxyEnvironment
    private let ledger: JSONLedgerFile<DeviceProxyLedger.Entry>
    private let gate: DeviceReleaseGate
    private weak var sink: CaptureSink?

    private var proxy: ProxyServer?
    private let passthrough = TLSPassthroughPolicy()
    private var port = 0
    private var previous: String?
    private var stopped = false
    /// What the arm task changed so far. The teardown undoes only these.
    private var ledgerWritten = false
    private var reverseAdded = false
    private var proxySet = false
    /// True once the arm task is past `settle`. Before that it changed nothing, so a stop does
    /// not wait for it (the arm task waits for the stop instead).
    private var armPastSettle = false

    /// The task that sets the device up. Internal so tests can await it.
    private(set) var armTask: Task<Void, Never>?
    /// The task that reverts the device. Internal so tests can await it.
    private(set) var teardownTask: Task<Void, Never>?

    /// Ports that a running source in this process holds, by serial. The lease check treats a
    /// ledger entry of this process on any other port as stale.
    private(set) static var armedPorts: [String: Set<Int>] = [:]

    init(device: Device, adbURL: URL?, ca: CertificateAuthority?, intercept: InterceptServices?,
         environment: DeviceProxyEnvironment = .live,
         ledger: JSONLedgerFile<DeviceProxyLedger.Entry> = DeviceProxyLedger.shared,
         gate: DeviceReleaseGate = .shared) {
        self.device = device
        self.adbURL = adbURL
        self.ca = ca
        self.intercept = intercept
        self.environment = environment
        self.ledger = ledger
        self.gate = gate
    }

    private var serial: String { device.id }

    var interceptCapabilities: InterceptCapabilities { intercept == nil ? [] : .desktopTerminated }
    /// Nothing to arm: the proxy is the only path, so the rules run whenever it listens.
    var interceptWired: Bool { intercept != nil }

    // MARK: - Start

    func start(into sink: CaptureSink) {
        self.sink = sink
        guard let ca else {
            sink.capture(didChangeStatus: "Couldn’t read Jaca’s certificate. Check ~/.jaca/jacad.log.")
            return
        }
        guard let adbURL else {
            sink.capture(didChangeStatus: AgentCaptureSource.unavailableMessage(device))
            return
        }
        let policy = passthrough
        let pipeline = intercept?.pipeline(for: .mitmProxy, deviceID: serial, appID: nil)
        let server = ProxyServer(
            port: 0, ca: ca, pipeline: pipeline,
            target: ProxyInterceptTarget(deviceID: serial),
            bindHost: "127.0.0.1",
            shouldDecrypt: { policy.shouldDecrypt($0) },
            onTransaction: { [weak sink] txn in Task { @MainActor in sink?.capture(didReceive: txn) } },
            onHandshake: { [weak self] host, ok in
                let verdict = policy.record(host: host, ok: ok)
                let needsSetup = !ok && !policy.anySuccess
                Task { @MainActor in self?.handshake(verdict: verdict, needsSetup: needsSetup) }
            })
        do {
            try server.start()
        } catch {
            sink.capture(didChangeStatus: "Couldn’t start the proxy: \(error.localizedDescription)")
            return
        }
        proxy = server
        port = server.boundPort
        Self.armedPorts[serial, default: []].insert(port)
        sink.capture(didChangeStatus: "Setting the device proxy…")
        let port = self.port
        armTask = Task { await arm(port: port, adbURL: adbURL) }
    }

    private func arm(port: Int, adbURL: URL) async {
        // A source restarted for an override change skips the precheck, so wait here too.
        await gate.settle(serial: serial)
        armPastSettle = true
        guard !stopped else { return }

        let reading = await DeviceProxyOps.read(adbURL: adbURL, serial: serial, environment: environment)
        guard !stopped else { return }
        if reading == .unreachable {
            fail(AgentCaptureSource.unavailableMessage(device))
            return
        }
        previous = reading.proxyValue
        let value = DeviceProxyPlan.loopbackValue(port: port)
        DeviceProxyLedger.add(DeviceProxyLedger.Entry(
            serial: serial, adbPath: adbURL.path, port: port, value: value, previous: previous,
            pid: environment.ownPid, createdAt: environment.now()), in: ledger)
        ledgerWritten = true

        let reverse = await environment.run(adbURL, DeviceProxyPlan.reverseAdd(serial: serial, port: port))
        guard reverse?.exitCode == 0 else {
            fail("Couldn’t start the proxy: \(DeviceProxyOps.errorText(reverse))")
            return
        }
        reverseAdded = true
        environment.cleanup.registerReverse(adbURL.path, serial, port)
        guard !stopped else { return }

        let put = await environment.run(adbURL, DeviceProxyPlan.arm(serial: serial, port: port))
        // Count the device as changed even when adb failed: the write may have landed.
        proxySet = true
        environment.cleanup.registerProxy(adbURL.path, serial, port, value)
        guard put?.exitCode == 0 else {
            fail("Couldn’t start the proxy: \(DeviceProxyOps.errorText(put))")
            return
        }
        guard !stopped else { return }
        sink?.capture(didBindPort: port)
        sink?.capture(didChangeStatus: "Capturing this device through Jaca's proxy")
    }

    /// Reports `message` and undoes what the arm task did. The engine keeps the tab in its
    /// running state with the message, as `MacBrowserCaptureSource` does on a bind failure.
    private func fail(_ message: String) {
        guard !stopped else { return }
        sink?.capture(didChangeStatus: message)
        beginTeardown(waitForArm: false)
    }

    private func handshake(verdict: TLSPassthroughPolicy.Verdict, needsSetup: Bool) {
        guard !stopped else { return }
        if case .passthroughAdded(let host) = verdict {
            sink?.capture(didChangeStatus: "Passing \(host) through — it rejects the certificate")
        }
        if needsSetup { sink?.captureNeedsSetup() }
    }

    func caTrustChanged() {
        passthrough.reset()
    }

    // MARK: - Stop

    func stop() {
        guard !stopped else { return }
        beginTeardown(waitForArm: armPastSettle)
    }

    private func beginTeardown(waitForArm: Bool) {
        stopped = true
        Self.armedPorts[serial]?.remove(port)
        if Self.armedPorts[serial]?.isEmpty == true { Self.armedPorts[serial] = nil }
        // The arm task calls this itself on a failure, so it must not wait for itself.
        let armTask = waitForArm ? self.armTask : nil
        let task = Task { @MainActor in
            await armTask?.value
            await self.teardown()
        }
        teardownTask = task
        gate.track(serial: serial, task: task)
    }

    private func teardown() async {
        var reverted = true
        if proxySet, let adbURL {
            let others = Set(DeviceProxyLedger.entries(serial: serial, in: ledger)
                .filter { $0.port != port }.map(\.value))
            reverted = await DeviceProxyOps.revert(
                adbURL: adbURL, serial: serial, value: DeviceProxyPlan.loopbackValue(port: port),
                previous: previous, otherValues: others, environment: environment)
            if reverted { environment.cleanup.deregisterProxy(adbURL.path, serial, port) }
        }
        if reverseAdded, let adbURL {
            _ = await environment.run(adbURL, DeviceProxyPlan.reverseRemove(serial: serial, port: port))
            environment.cleanup.deregisterReverse(adbURL.path, serial, port)
        }
        proxy?.stop()
        proxy = nil
        if ledgerWritten {
            if reverted {
                DeviceProxyLedger.remove(serial: serial, port: port, in: ledger)
            } else {
                // No capture holds the value now. Marked, so the sidebar offers Revert and the
                // next reconcile repairs it, even while this process still runs.
                DeviceProxyLedger.markReleased(serial: serial, port: port, in: ledger)
            }
        }
        if !reverted {
            JacaLog.error("proxy", "couldn't revert the device proxy on \(serial):\(port)")
            sink?.capture(didChangeStatus: "Couldn’t remove the device proxy. Use Revert in the sidebar.")
        }
    }

    // MARK: - Readiness (the descriptor's precheck)

    /// The device must be online over adb, its last teardown finished, and no other live Jaca
    /// process may hold its proxy. Returns a message to abort, or nil when ready.
    static func precheck(device: Device, adbURL: URL?,
                         ledger: JSONLedgerFile<DeviceProxyLedger.Entry> = DeviceProxyLedger.shared,
                         gate: DeviceReleaseGate = .shared,
                         environment: DeviceProxyEnvironment = .live) async -> String? {
        guard let adbURL,
              await DeviceProxyOps.isOnline(adbURL: adbURL, serial: device.id, environment: environment)
        else { return AgentCaptureSource.unavailableMessage(device) }
        return await DeviceProxyLease.check(serial: device.id, adbURL: adbURL, ledger: ledger,
                                            gate: gate, environment: environment)
    }
}

// MARK: - Environment

/// The side effects of the device proxy, as closures so tests never touch a device, this Mac's
/// adb server or the real cleanup registries.
struct DeviceProxyEnvironment: Sendable {
    /// The process-global registries that revert on quit and on a catchable signal.
    struct Cleanup: Sendable {
        var registerReverse: @Sendable (_ adbPath: String, _ serial: String, _ port: Int) -> Void
        var deregisterReverse: @Sendable (_ adbPath: String, _ serial: String, _ port: Int) -> Void
        var registerProxy: @Sendable (_ adbPath: String, _ serial: String, _ port: Int, _ value: String) -> Void
        var deregisterProxy: @Sendable (_ adbPath: String, _ serial: String, _ port: Int) -> Void

        static let live = Cleanup(
            registerReverse: { AdbTunnelCleanup.register(adbPath: $0, serial: $1, kind: .reverse, port: $2) },
            deregisterReverse: { AdbTunnelCleanup.deregister(adbPath: $0, serial: $1, kind: .reverse, port: $2) },
            registerProxy: { ProxyCleanup.register(adbPath: $0, serial: $1, port: $2, value: $3) },
            deregisterProxy: { ProxyCleanup.deregister(adbPath: $0, serial: $1, port: $2) })

        static let none = Cleanup(registerReverse: { _, _, _ in }, deregisterReverse: { _, _, _ in },
                                  registerProxy: { _, _, _, _ in }, deregisterProxy: { _, _, _ in })
    }

    /// Runs adb with `arguments`. nil when adb could not be launched.
    var run: @Sendable (_ adbURL: URL, _ arguments: [String]) async -> CommandRunner.Result?
    /// The wait between Wi-Fi off and on when the proxy is cleared.
    var pause: @Sendable (_ seconds: Double) async -> Void
    var pidAlive: @Sendable (Int32) -> Bool
    var ownPid: Int32
    var now: @Sendable () -> Date
    var isExecutable: @Sendable (String) -> Bool
    var cleanup: Cleanup

    static let live = DeviceProxyEnvironment(
        run: { adbURL, arguments in try? await CommandRunner.run(adbURL, arguments, timeout: 30) },
        pause: { seconds in try? await Task.sleep(for: .seconds(seconds)) },
        pidAlive: DeviceProxyLedger.liveOwnerCheck,
        ownPid: ProcessInfo.processInfo.processIdentifier,
        now: { Date() },
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
        cleanup: .live)

    /// The same operations in the shape `DeviceProxyLedger.reconcileOrphans` takes.
    var proxyCommands: AndroidProxyCommands {
        let env = self
        return AndroidProxyCommands(
            read: { adbURL, serial in await DeviceProxyOps.read(adbURL: adbURL, serial: serial, environment: env) },
            set: { adbURL, serial, value in
                _ = await env.run(adbURL, DeviceProxyPlan.setProxy(serial: serial, value: value))
            },
            clear: { adbURL, serial in await DeviceProxyOps.clear(adbURL: adbURL, serial: serial, environment: env) })
    }
}

/// The adb steps of the device proxy, run through a `DeviceProxyEnvironment`.
enum DeviceProxyOps {
    static func isOnline(adbURL: URL, serial: String, environment: DeviceProxyEnvironment) async -> Bool {
        let r = await environment.run(adbURL, ["-s", serial, "get-state"])
        return r?.exitCode == 0 && (r?.stdout.contains("device") ?? false)
    }

    static func read(adbURL: URL, serial: String, environment: DeviceProxyEnvironment) async -> AndroidProxyReading {
        let r = await environment.run(adbURL, DeviceProxyPlan.readProxy(serial: serial))
        return AndroidProxyReading.parse(exitCode: r?.exitCode, stdout: r?.stdout ?? "")
    }

    /// Clears every proxy key, then bounces Wi-Fi so Android validates the network again (see
    /// `ProxyConfigurator.clearAndroidProxy`).
    static func clear(adbURL: URL, serial: String, environment: DeviceProxyEnvironment) async {
        for arguments in DeviceProxyPlan.clear(serial: serial) {
            _ = await environment.run(adbURL, arguments)
        }
        _ = await environment.run(adbURL, ["-s", serial, "shell", "svc", "wifi", "disable"])
        await environment.pause(2)
        _ = await environment.run(adbURL, ["-s", serial, "shell", "svc", "wifi", "enable"])
    }

    /// Compare-and-restore. Reads the device first, and changes it only while it still reads
    /// `value`: a device that reads another value now belongs to whoever set it (the user, or a
    /// newer Jaca capture), so it is left as it is. Then puts back what the device had before
    /// Jaca, or clears the proxy, and reads the device to check. Returns true when the device no
    /// longer reads `value`. An unreachable device counts as not reverted, so its ledger entry
    /// stays.
    static func revert(adbURL: URL, serial: String, value: String, previous: String?,
                       otherValues: Set<String>, environment: DeviceProxyEnvironment) async -> Bool {
        let before = await read(adbURL: adbURL, serial: serial, environment: environment)
        guard before == .value(value) else { return isReverted(before, value: value) }
        if let restore = DeviceProxyLedger.restoreTarget(previous: previous, otherValues: otherValues) {
            _ = await environment.run(adbURL, DeviceProxyPlan.restorePrevious(serial: serial, previous: restore))
        } else {
            await clear(adbURL: adbURL, serial: serial, environment: environment)
        }
        return isReverted(await read(adbURL: adbURL, serial: serial, environment: environment), value: value)
    }

    /// Whether a reading after a revert shows the device off Jaca's `value`.
    static func isReverted(_ reading: AndroidProxyReading, value: String) -> Bool {
        switch reading {
        case .unreachable: return false
        case .noProxy: return true
        case .value(let v): return v != value
        }
    }

    /// adb's own words for a failed call, for the status line.
    static func errorText(_ result: CommandRunner.Result?) -> String {
        guard let result else { return "couldn't run adb" }
        let text = (result.stderr + " " + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit \(result.exitCode)" : text
    }
}

// MARK: - Lease

/// Who holds a device's proxy, from the `DeviceProxyLedger` entries of its serial. Both adb
/// prechecks (agent and device proxy) run it, so a capture never arms on a device that another
/// live Jaca process (the app or jacad) has pointed at its own proxy.
enum DeviceProxyLease {
    enum Verdict: Equatable, Sendable {
        /// Another live process holds the proxy. Refuse the start and touch nothing.
        case heldElsewhere
        /// Nobody else holds it. Revert `ownStale`, entries this process left behind (a stop
        /// whose revert failed).
        case free(ownStale: [DeviceProxyLedger.Entry])
    }

    static let heldElsewhereMessage = "Another Jaca process is using this device's proxy. Stop that capture first."

    /// - Parameter armedPorts: the ports a running source of this process holds on the serial.
    static func verdict(entries: [DeviceProxyLedger.Entry], ownPid: Int32, armedPorts: Set<Int>,
                        pidAlive: (Int32) -> Bool, now: Date) -> Verdict {
        let foreignLive = entries.contains { entry in
            entry.pid != ownPid
                && !DeviceProxyLedger.isAbandoned(entry: entry, pidAlive: pidAlive(entry.pid),
                                                  isOwnPid: false, now: now)
        }
        if foreignLive { return .heldElsewhere }
        return .free(ownStale: entries.filter { $0.pid == ownPid && !armedPorts.contains($0.port) })
    }

    /// Waits for the device's last teardown, then applies the verdict: refuse, or revert this
    /// process's stale entries and reconcile the entries of dead processes. Returns a message to
    /// abort, or nil.
    @MainActor
    static func check(serial: String, adbURL: URL,
                      ledger: JSONLedgerFile<DeviceProxyLedger.Entry> = DeviceProxyLedger.shared,
                      gate: DeviceReleaseGate = .shared,
                      environment: DeviceProxyEnvironment = .live,
                      armedPorts: Set<Int>? = nil) async -> String? {
        await gate.settle(serial: serial)
        let entries = DeviceProxyLedger.entries(serial: serial, in: ledger)
        let armed = armedPorts ?? DeviceProxyCaptureSource.armedPorts[serial] ?? []
        switch verdict(entries: entries, ownPid: environment.ownPid, armedPorts: armed,
                       pidAlive: environment.pidAlive, now: environment.now()) {
        case .heldElsewhere:
            return heldElsewhereMessage
        case .free(let stale):
            for entry in stale {
                await revertOwn(entry, all: entries, adbURL: adbURL, ledger: ledger, environment: environment)
            }
        }
        await DeviceProxyLedger.reconcileOrphans(
            adbPath: adbURL.path, serial: serial, in: ledger, commands: environment.proxyCommands,
            pidAlive: environment.pidAlive, ownPid: environment.ownPid,
            isExecutable: environment.isExecutable, now: environment.now())
        return nil
    }

    /// Reverts one stale entry of this process: compare-and-restore, as reconcile does for a dead
    /// process. A device that reads another value now is left alone and the entry is dropped.
    private static func revertOwn(_ entry: DeviceProxyLedger.Entry, all: [DeviceProxyLedger.Entry],
                                  adbURL: URL, ledger: JSONLedgerFile<DeviceProxyLedger.Entry>,
                                  environment: DeviceProxyEnvironment) async {
        let reading = await DeviceProxyOps.read(adbURL: adbURL, serial: entry.serial, environment: environment)
        let reverted: Bool
        switch reading {
        case .unreachable:
            return
        case .noProxy, .value:
            if reading.proxyValue == entry.value {
                let others = Set(all.filter { $0.port != entry.port }.map(\.value))
                reverted = await DeviceProxyOps.revert(
                    adbURL: adbURL, serial: entry.serial, value: entry.value, previous: entry.previous,
                    otherValues: others, environment: environment)
            } else {
                reverted = true
            }
        }
        _ = await environment.run(adbURL, DeviceProxyPlan.reverseRemove(serial: entry.serial, port: entry.port))
        environment.cleanup.deregisterReverse(adbURL.path, entry.serial, entry.port)
        guard reverted else {
            JacaLog.error("proxy", "couldn't revert a stale device proxy on \(entry.serial):\(entry.port)")
            return
        }
        environment.cleanup.deregisterProxy(adbURL.path, entry.serial, entry.port)
        DeviceProxyLedger.remove(serial: entry.serial, port: entry.port, in: ledger)
    }
}
