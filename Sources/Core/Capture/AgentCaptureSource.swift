import Foundation

/// In-process agent capture for one debuggable Android app (no proxy, no CA). Attaches
/// via the bundled agent artifacts and reports transactions (with call stacks) + status.
@MainActor
final class AgentCaptureSource: CaptureSource {
    private let adbURL: URL?
    private let serial: String
    private let package: String
    private let intercept: InterceptServices?
    private let gate: DeviceReleaseGate
    private var controller: AgentController?

    init(adbURL: URL?, serial: String, package: String, intercept: InterceptServices? = nil,
         gate: DeviceReleaseGate = .shared) {
        self.adbURL = adbURL
        self.serial = serial
        self.package = package
        self.intercept = intercept
        self.gate = gate
    }

    /// The agent terminates the exchange on the desktop, so it can do everything: answer without
    /// the network, rewrite a real response, delay, and see bodies.
    ///
    /// One constant, two readers — the UI below and `AgentHTTPServer` via the controller — so the
    /// toolbar can't promise more than the clamp allows.
    static let nativeCapabilities: InterceptCapabilities = .desktopTerminated

    /// …**but only when override services were actually wired in**. Without them nothing can be
    /// honoured here, so the source declares nothing.
    var interceptCapabilities: InterceptCapabilities { intercept == nil ? [] : Self.nativeCapabilities }

    var arming: AgentHTTPCoordinator? { controller?.agentHTTP }

    func start(into sink: CaptureSink) {
        guard let adbURL, !package.isEmpty,
              let so = AgentArtifacts.soURL(), let boot = AgentArtifacts.bootDexURL,
              let cap = AgentArtifacts.captureDexURL else {
            sink.capture(didChangeStatus: "The in-process agent isn't available for this app.")
            return
        }
        let controller = AgentController(
            adbURL: adbURL, serial: serial, package: package,
            soPath: so, bootDexPath: boot, captureDexPath: cap,
            onTransaction: { [weak sink] txn in Task { @MainActor in sink?.capture(didReceive: txn) } },
            onStatus: { [weak sink] s in Task { @MainActor in sink?.capture(didChangeStatus: s) } },
            capabilities: Self.nativeCapabilities,
            intercept: intercept
        )
        self.controller = controller
        controller.start()
    }

    /// The controller removes its tunnels in a task. The gate tracks it, so the next capture on
    /// this device arms only after the reverse and the forward are gone.
    func stop() {
        guard let controller else { return }
        self.controller = nil
        gate.track(serial: serial, task: controller.stop())
    }

    // MARK: - Readiness (used as the descriptor's precheck)

    /// Agent mode must reach the device to attach in-process, and the app must exist. On
    /// Android it also waits for the device's last teardown and refuses a device whose proxy
    /// another live Jaca process holds (`DeviceProxyLease`).
    /// Returns a clear error message to abort, or nil when ready.
    static func precheck(device: Device, adbURL: URL?, package: String?,
                         ledger: JSONLedgerFile<DeviceProxyLedger.Entry> = DeviceProxyLedger.shared,
                         gate: DeviceReleaseGate = .shared,
                         environment: DeviceProxyEnvironment = .live,
                         artifactsAvailable: Bool = AgentArtifacts.isAvailable) async -> String? {
        guard artifactsAvailable else { return AgentArtifacts.missingMessage }
        guard await deviceAvailable(device, adbURL, environment) else { return unavailableMessage(device) }
        if device.platform == .android, let adbURL,
           let refusal = await DeviceProxyLease.check(serial: device.id, adbURL: adbURL, ledger: ledger,
                                                      gate: gate, environment: environment) {
            return refusal
        }
        if device.platform == .android, let pkg = package, !pkg.isEmpty,
           await !packageInstalled(pkg, device: device, adbURL: adbURL, environment) {
            return "App “\(pkg)” isn’t installed on \(device.displayModel)."
        }
        return nil
    }

    private static func deviceAvailable(_ device: Device, _ adbURL: URL?,
                                        _ environment: DeviceProxyEnvironment) async -> Bool {
        switch device.platform {
        case .android:
            guard let adbURL else { return false }
            return await DeviceProxyOps.isOnline(adbURL: adbURL, serial: device.id, environment: environment)
        case .iosSimulator:
            let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "list", "devices", "booted"])
            return r?.stdout.contains(device.id) ?? false
        case .iosDevice:
            let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["devicectl", "list", "devices"], timeout: 12)
            return r?.stdout.contains(device.id) ?? false
        case .mac:
            return false   // the agent isn't offered for this Mac
        }
    }

    private static func packageInstalled(_ package: String, device: Device, adbURL: URL?,
                                         _ environment: DeviceProxyEnvironment) async -> Bool {
        guard let adbURL else { return false }
        let r = await environment.run(adbURL, ["-s", device.id, "shell", "pm", "list", "packages", package])
        return r?.stdout.contains("package:\(package)") ?? false
    }

    /// Shared with the device proxy precheck.
    static func unavailableMessage(_ device: Device) -> String {
        switch device.platform {
        case .android: return "\(device.displayModel) isn’t connected — plug it in and authorize USB debugging."
        case .iosSimulator: return "\(device.displayModel) isn’t booted — start the simulator and try again."
        case .iosDevice: return "\(device.displayModel) isn’t connected — plug it in and trust this Mac."
        case .mac: return "\(device.displayModel) captures through Chrome, not the in-process agent."
        }
    }
}
