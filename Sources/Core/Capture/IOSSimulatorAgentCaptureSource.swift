import Foundation

/// In-process agent capture for a debug app on the iOS **Simulator** — the iOS counterpart of
/// `AgentCaptureSource`. Wraps `IOSSimulatorAgentController`, which injects the bundled
/// `JacaNetAgent` dylib via `simctl launch` + `DYLD_INSERT_LIBRARIES` and streams the agent's
/// JSON through the shared `AgentTransactionParser`. No proxy, no CA.
@MainActor
final class IOSSimulatorAgentCaptureSource: CaptureSource {
    private let device: Device
    private let bundleID: String
    private let intercept: InterceptServices?
    private var controller: IOSSimulatorAgentController?

    init(device: Device, bundleID: String, intercept: InterceptServices? = nil) {
        self.device = device
        self.bundleID = bundleID
        self.intercept = intercept
    }

    /// The agent terminates the exchange on the desktop, so it can do everything: answer without
    /// the network, rewrite a real response, delay, and see bodies.
    ///
    /// One constant, two readers — the UI below and `OverrideServer` via the coordinator — so the
    /// toolbar can't promise more than the clamp allows.
    static let nativeCapabilities: InterceptCapabilities = .desktopTerminated

    /// …**but only when override services were actually wired in**. Without them nothing can be
    /// honoured here, so an unwired source declares nothing rather than claiming it can override.
    var interceptCapabilities: InterceptCapabilities { intercept == nil ? [] : Self.nativeCapabilities }

    var arming: DivertCoordinator? { controller?.divert }

    func start(into sink: CaptureSink) {
        guard !bundleID.isEmpty, let dylib = AgentArtifacts.iosNetworkAgentURL else {
            sink.capture(didChangeStatus: AgentArtifacts.iosMissingMessage)
            return
        }
        let controller = IOSSimulatorAgentController(
            udid: device.id, bundleID: bundleID, agentDylib: dylib,
            capabilities: Self.nativeCapabilities,
            onTransaction: { [weak sink] txn in Task { @MainActor in sink?.capture(didReceive: txn) } },
            onStatus: { [weak sink] s in Task { @MainActor in sink?.capture(didChangeStatus: s) } },
            onAttach: { [weak sink] state in
                Task { @MainActor in sink?.capture(didChangeAttach: state) }
            },
            intercept: intercept
        )
        // Assigned **before** `start()`, and the coordinator is a `let`, so `arming` is non-nil
        // as soon as the source runs. `interceptWired` is only re-evaluated when `current` is
        // assigned, so building this asynchronously would leave the toolbar reading as unarmed.
        self.controller = controller
        controller.start()
    }

    func stop() { controller?.stop(); controller = nil }

    /// The attach banner's action: relaunch with the agent injected after the user reopened the
    /// app outside Jaca. Off the `CaptureSource` protocol — only this transport can do it.
    func relaunchToAttach() {
        guard let controller else { return }
        Task { await controller.relaunchToAttach() }
    }

    /// Readiness (the descriptor's precheck): the agent dylib must be bundled, the simulator
    /// booted, and an app chosen. Returns a clear message to abort, or nil when ready.
    static func precheck(device: Device, bundleID: String?) async -> String? {
        guard AgentArtifacts.iosNetworkAgentAvailable else { return AgentArtifacts.iosMissingMessage }
        let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "list", "devices", "booted"])
        guard r?.stdout.contains(device.id) ?? false else {
            return "\(device.displayModel) isn’t booted — start the simulator and try again."
        }
        guard let id = bundleID, !id.isEmpty else { return "Pick an app to inspect on \(device.displayModel)." }
        return nil
    }
}
