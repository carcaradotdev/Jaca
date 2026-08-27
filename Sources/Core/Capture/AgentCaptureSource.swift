import Foundation

/// In-process agent capture for one debuggable Android app (no proxy, no CA). Attaches
/// via the bundled agent artifacts and reports transactions (with call stacks) + status.
@MainActor
final class AgentCaptureSource: CaptureSource {
    private let adbURL: URL?
    private let serial: String
    private let package: String
    private let intercept: InterceptServices?
    private var controller: AgentController?

    init(adbURL: URL?, serial: String, package: String, intercept: InterceptServices? = nil) {
        self.adbURL = adbURL
        self.serial = serial
        self.package = package
        self.intercept = intercept
    }

    /// The agent terminates the exchange on the desktop, so it can do everything: answer without
    /// the network, rewrite a real response, delay, and see bodies — **but only when override
    /// services were actually wired in**. Without them nothing can be honoured here.
    var interceptCapabilities: InterceptCapabilities { intercept == nil ? [] : .desktopTerminated }

    var arming: AgentDivertCoordinator? { controller?.divert }

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
            intercept: intercept
        )
        self.controller = controller
        controller.start()
    }

    func stop() { controller?.stop(); controller = nil }

    // MARK: - Readiness (used as the descriptor's precheck)

    /// Agent mode must reach the device to attach in-process, and the app must exist.
    /// Returns a clear error message to abort, or nil when ready.
    static func precheck(device: Device, adbURL: URL?, package: String?) async -> String? {
        guard AgentArtifacts.isAvailable else { return AgentArtifacts.missingMessage }
        guard await deviceAvailable(device, adbURL) else { return unavailableMessage(device) }
        if device.platform == .android, let pkg = package, !pkg.isEmpty,
           await !packageInstalled(pkg, device: device, adbURL: adbURL) {
            return "App “\(pkg)” isn’t installed on \(device.displayModel)."
        }
        return nil
    }

    private static func deviceAvailable(_ device: Device, _ adbURL: URL?) async -> Bool {
        switch device.platform {
        case .android:
            guard let adbURL else { return false }
            let r = try? await CommandRunner.run(adbURL, ["-s", device.id, "get-state"])
            return r?.exitCode == 0 && (r?.stdout.contains("device") ?? false)
        case .iosSimulator:
            let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "list", "devices", "booted"])
            return r?.stdout.contains(device.id) ?? false
        case .iosDevice:
            let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["devicectl", "list", "devices"], timeout: 12)
            return r?.stdout.contains(device.id) ?? false
        }
    }

    private static func packageInstalled(_ package: String, device: Device, adbURL: URL?) async -> Bool {
        guard let adbURL else { return false }
        let r = try? await CommandRunner.run(adbURL, ["-s", device.id, "shell", "pm", "list", "packages", package])
        return r?.stdout.contains("package:\(package)") ?? false
    }

    private static func unavailableMessage(_ device: Device) -> String {
        switch device.platform {
        case .android: return "\(device.displayModel) isn’t connected — plug it in and authorize USB debugging."
        case .iosSimulator: return "\(device.displayModel) isn’t booted — start the simulator and try again."
        case .iosDevice: return "\(device.displayModel) isn’t connected — plug it in and trust this Mac."
        }
    }
}
