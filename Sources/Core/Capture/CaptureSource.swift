import Foundation

/// Dependencies handed to a capture source when it's built. Sources pull only what they
/// need, so they stay decoupled from `NetworkSession`/`AppModel` internals.
@MainActor
struct CaptureContext {
    let device: Device
    let adbURL: URL?
    let ca: CertificateAuthority
    let deviceContext: DeviceContext?
    /// Agent mode: the debuggable app to attach to.
    let targetPackage: String?
    /// Companion mode: the shared mDNS browse + stream hub.
    let companion: CompanionHub?
    /// The resolver, reporter and origin client a transport needs to participate in interception;
    /// nil disables overriding here. Threaded like `companion` above, so sources never reach for
    /// the model.
    var intercept: InterceptServices? = nil
}

/// Callbacks a running source uses to report back to its session. Source-specific
/// concerns (bound port, "device may not trust the CA yet") are events here, so the
/// session never switches on a capture mode.
@MainActor
protocol CaptureSink: AnyObject {
    func capture(didReceive transaction: NetworkTransaction)
    func capture(didChangeStatus status: String?)
    func capture(didBindPort port: Int)
    /// Proxy: started, but no decrypted HTTPS seen yet — guide the user to install/trust the CA.
    func captureNeedsSetup()

    /// The source's in-process agent is no longer in the app (or the app is gone). Separate from
    /// `arming` because losing the agent stops **capture**, not just overrides, so it must reach
    /// the UI even when overrides were never wired. Only the iOS-Simulator source detects it.
    func capture(didChangeAttach state: InterceptArmingState)
}

/// A pluggable network-capture backend. Add a new way to capture (proxy, in-process
/// agent, companion stream, anything future) by conforming here and registering a
/// `CaptureSourceDescriptor` — `NetworkSession` and the UI consume the registry
/// generically, so nothing already working has to change.
@MainActor
protocol CaptureSource: AnyObject {
    func start(into sink: CaptureSink)
    func stop()
    /// What this source can honour when a rule matches. Defaults to nothing, so a transport
    /// only participates in interception once it deliberately opts in.
    var interceptCapabilities: InterceptCapabilities { get }

    /// The coordinator arming this source's device, when overrides were actually wired up.
    /// Nil means nothing is armed — the UI must not claim overrides are active.
    var arming: DivertCoordinator? { get }
}

extension CaptureSink {
    func capture(didChangeAttach state: InterceptArmingState) {}
}

extension CaptureSource {
    var interceptCapabilities: InterceptCapabilities { [] }
    var arming: DivertCoordinator? { nil }
}

/// Static, selectable description of a capture option for a device. Drives the chooser
/// and builds the source on demand.
@MainActor
struct CaptureSourceDescriptor: Identifiable {
    let id: String
    let kind: CaptureMode
    let title: String
    let detail: String
    /// Whether this option is offered for the given device.
    let isAvailable: (Device, DeviceContext?) -> Bool
    /// True if choosing it requires picking a target app first (agent).
    let needsPackage: Bool
    /// Optional readiness check run before starting; return an error message to abort
    /// (e.g. agent needs the device reachable + the app installed). nil = start directly.
    var precheck: ((CaptureContext) async -> String?)? = nil
    /// Builds a fresh running source.
    let make: (CaptureContext) -> CaptureSource

    var label: String { kind.label }
}
