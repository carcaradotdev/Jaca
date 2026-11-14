import Foundation

/// Capture-side state of a network tab: which source was chosen and how it's doing. Published by
/// `jacad` on `net.state.<id>`.
struct NetworkCaptureState: Codable, Equatable, Sendable {
    var isRunning = false
    var isConnecting = false
    var statusMessage: String?
    var boundPort = 0
    /// Proxy started but the CA isn't confirmed — the view surfaces the setup dialog.
    var proxyNeedsSetup = false
    /// Ground truth that the CA is trusted: flips true once a real HTTPS request is decrypted.
    var caReady = false
    /// The chosen capture source (registry id), and whether the user has chosen one.
    var selectedSourceID: String?
    var hasSelectedMode = false
    /// Agent mode: the debuggable app to attach to. nil otherwise.
    var targetPackage: String?
    /// What the source last reported about its agent (only the iOS-Simulator source detects a
    /// lost agent). Separate from override arming: losing the agent stops capture either way.
    var attachState: InterceptArmingState = .idle
    /// Whether the running source was handed override services (something is armed).
    var interceptWired = false
    /// What the running source can honour when a rule matches (`InterceptCapabilities.rawValue`).
    var interceptCapabilities = 0
    /// Whether any capture source is running.
    var hasRunningSource = false
    /// The capture source ids the current network inspection mode offers for this device, in
    /// chooser order. Clients build the chooser from it, so none of them repeats the strategy.
    var offeredSourceIDs: [String] = []
}

extension NetworkCaptureState {
    private enum CodingKeys: String, CodingKey {
        case isRunning, isConnecting, statusMessage, boundPort, proxyNeedsSetup, caReady
        case selectedSourceID, hasSelectedMode, targetPackage
        case attachState, interceptWired, interceptCapabilities, hasRunningSource
        case offeredSourceIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isRunning: try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false,
            isConnecting: try c.decodeIfPresent(Bool.self, forKey: .isConnecting) ?? false,
            statusMessage: try c.decodeIfPresent(String.self, forKey: .statusMessage),
            boundPort: try c.decodeIfPresent(Int.self, forKey: .boundPort) ?? 0,
            proxyNeedsSetup: try c.decodeIfPresent(Bool.self, forKey: .proxyNeedsSetup) ?? false,
            caReady: try c.decodeIfPresent(Bool.self, forKey: .caReady) ?? false,
            selectedSourceID: try c.decodeIfPresent(String.self, forKey: .selectedSourceID),
            hasSelectedMode: try c.decodeIfPresent(Bool.self, forKey: .hasSelectedMode) ?? false,
            targetPackage: try c.decodeIfPresent(String.self, forKey: .targetPackage),
            attachState: (try? c.decodeIfPresent(InterceptArmingState.self, forKey: .attachState)) ?? .idle,
            interceptWired: try c.decodeIfPresent(Bool.self, forKey: .interceptWired) ?? false,
            interceptCapabilities: try c.decodeIfPresent(Int.self, forKey: .interceptCapabilities) ?? 0,
            hasRunningSource: try c.decodeIfPresent(Bool.self, forKey: .hasRunningSource) ?? false,
            offeredSourceIDs: (try? c.decodeIfPresent([String].self, forKey: .offeredSourceIDs)) ?? []
        )
    }
}

/// Where a `NetworkSession` tab gets its transactions and capture state: an in-process
/// `NetworkCaptureEngine`, or a capture running in `jacad`.
@MainActor
protocol NetworkFeed: AnyObject {
    var state: NetworkCaptureState { get }
    /// New or updated transactions (upserts by id), in arrival order.
    var onTransactions: (([NetworkTransaction]) -> Void)? { get set }
    var onState: ((NetworkCaptureState) -> Void)? { get set }
    /// Whether transactions arrive without bodies, to be fetched with `bodies(for:)`.
    var bodiesOnDemand: Bool { get }

    /// Choose a capture source and start it.
    func select(sourceID: String, package: String?)
    /// Restore the chosen source without starting.
    func restoreMode(sourceID: String?, package: String?)
    /// Back to the source chooser.
    func reopenChooser()
    /// Restart the chosen source.
    func resume()
    func stop()
    func clearProxyNeedsSetup()
    /// Forget captured transactions (the tab cleared its list).
    func clear()
    /// nil when the bodies can't be had right now (the daemon is gone, or the capture closed).
    func bodies(for id: UUID) async -> (req: Data?, resp: Data?)?
    /// The whole capture as HAR, from the side that holds the bodies.
    func harData() async -> Data?
    /// Restarts the running source so it picks up a changed override configuration (the
    /// services are snapshotted at launch). Keeps the captured rows.
    func restartForInterceptChange()
    /// iOS Simulator: relaunch the app to put the agent back (the attach banner's action).
    func relaunchToAttach()
    /// This Mac: open the Chrome window again after the user closed it.
    func openBrowser()
    /// Ends the capture for good (the tab closed).
    func close()
}

/// One network capture with everything that isn't a view: choosing a `CaptureSource` from
/// `CaptureSourceRegistry`, prechecking and running it, and receiving its events as the
/// `CaptureSink`. Transactions are handed on as they arrive.
///
/// The app runs one per network tab when the daemon is off; `jacad` runs one per capture when
/// the network area is on.
@MainActor
final class NetworkCaptureEngine: NetworkFeed, CaptureSink {
    let id: UUID
    let device: Device

    private(set) var state = NetworkCaptureState() {
        didSet { if state != oldValue { onState?(state) } }
    }
    var onTransactions: (([NetworkTransaction]) -> Void)?
    var onState: ((NetworkCaptureState) -> Void)?
    var bodiesOnDemand: Bool { false }
    /// Provides the transactions to export as HAR (the view's list, in-process).
    var harSource: (() -> [NetworkTransaction])?

    private let adbURL: URL?
    /// Read when a source is built, so a capture opened before the CA loaded (or before a mode
    /// switch made it need one) still finds it.
    private let ca: () -> CertificateAuthority?
    private let companion: CompanionHub?
    private let deviceContext: () -> DeviceContext?
    /// Override services for a new source, or nil when overrides are off.
    private let interceptServices: () -> InterceptServices?
    private var current: CaptureSource? {
        didSet { publishSourceFacts() }
    }
    /// Counts starts and stops. A precheck launches its source only while the count is still
    /// the one it began with, so a stop during the precheck cancels the launch.
    private var startGeneration = 0

    /// Asked before a source is chosen and started, with this engine's id, the source and the
    /// package. False refuses the start and leaves the state as it is. The owner of several
    /// in-process engines uses it to refuse a start during a mode switch and to stop the other
    /// captures whose claim on the device collides (`DeviceClaimArbiter`). jacad does both in
    /// `NetworkArea`, so it leaves this nil.
    var startGate: ((_ id: UUID, _ sourceID: String, _ package: String?) -> Bool)?

    init(id: UUID = UUID(), device: Device, adbURL: URL?, ca: @escaping () -> CertificateAuthority?,
         companion: CompanionHub?, deviceContext: @escaping () -> DeviceContext?,
         interceptServices: @escaping () -> InterceptServices? = { nil }) {
        self.id = id
        self.device = device
        self.adbURL = adbURL
        self.ca = ca
        self.companion = companion
        self.deviceContext = deviceContext
        self.interceptServices = interceptServices
        refreshOffered()
    }

    /// An engine with a CA that is already loaded (or known to be missing).
    convenience init(id: UUID = UUID(), device: Device, adbURL: URL?, ca: CertificateAuthority?,
                     companion: CompanionHub?, deviceContext: @escaping () -> DeviceContext?,
                     interceptServices: @escaping () -> InterceptServices? = { nil }) {
        self.init(id: id, device: device, adbURL: adbURL, ca: { ca }, companion: companion,
                  deviceContext: deviceContext, interceptServices: interceptServices)
    }

    /// Reads the offered source ids from the current strategy into the state. Call it after the
    /// network inspection mode changes. jacad passes the strategy of the mode it owns.
    func refreshOffered(strategy: any HTTPDebuggingStrategy = HTTPDebuggingStrategies.current) {
        state.offeredSourceIDs = CaptureSourceRegistry.options(for: device, context: deviceContext(),
                                                               strategy: strategy).map(\.id)
    }

    /// The facts about the running source the toolbar and banner need.
    private func publishSourceFacts() {
        state.interceptWired = current?.interceptWired ?? false
        state.interceptCapabilities = current?.interceptCapabilities.rawValue ?? 0
        state.hasRunningSource = current != nil
    }

    private var currentDescriptor: CaptureSourceDescriptor? {
        state.selectedSourceID.flatMap { CaptureSourceRegistry.descriptor(id: $0) }
    }

    // MARK: - Source selection

    func select(sourceID: String, package: String?) {
        guard let descriptor = CaptureSourceRegistry.descriptor(id: sourceID) else { return }
        let gatedPackage = descriptor.needsPackage ? package : nil
        if let startGate, !startGate(id, descriptor.id, gatedPackage) { return }
        if state.isRunning { stop() }
        state.targetPackage = descriptor.needsPackage ? package : nil
        state.selectedSourceID = descriptor.id
        state.hasSelectedMode = true
        start()
    }

    func restoreMode(sourceID: String?, package: String?) {
        guard let sourceID, let descriptor = CaptureSourceRegistry.descriptor(id: sourceID) else { return }
        state.selectedSourceID = descriptor.id
        state.targetPackage = descriptor.needsPackage ? package : nil
        state.hasSelectedMode = true
    }

    func reopenChooser() {
        if state.isRunning { stop() }
        state.hasSelectedMode = false
        state.proxyNeedsSetup = false
    }

    func resume() {
        guard state.hasSelectedMode, let descriptor = currentDescriptor else { return }
        select(sourceID: descriptor.id, package: state.targetPackage)
    }

    func start() {
        guard !state.isRunning, !state.isConnecting, state.hasSelectedMode, let descriptor = currentDescriptor else { return }
        state.statusMessage = nil
        guard let precheck = descriptor.precheck else { launch(descriptor); return }
        // A source that needs the device reachable (agent) verifies first and surfaces a
        // clear message instead of silently failing.
        state.isConnecting = true
        startGeneration &+= 1
        let generation = startGeneration
        Task { @MainActor in
            let error = await precheck(makeContext())
            // A stop or a newer start during the precheck owns the state now.
            guard generation == startGeneration else { return }
            state.isConnecting = false
            if let error { state.statusMessage = error; return }
            // A mode switch can show the chooser while the precheck runs. Then the source is
            // no longer chosen, and must not start.
            guard state.hasSelectedMode, state.selectedSourceID == descriptor.id else { return }
            launch(descriptor)
        }
    }

    private func launch(_ descriptor: CaptureSourceDescriptor) {
        guard !state.isRunning else { return }
        state.isRunning = true
        state.attachState = .idle
        let source = descriptor.make(makeContext())
        current = source
        source.start(into: self)
    }

    private func makeContext() -> CaptureContext {
        CaptureContext(device: device, adbURL: adbURL, ca: ca(), deviceContext: deviceContext(),
                       targetPackage: state.targetPackage, companion: companion,
                       intercept: interceptServices())
    }

    func restartForInterceptChange() {
        guard state.isRunning, let descriptor = currentDescriptor else { return }
        current?.stop()
        current = nil
        state.attachState = .idle
        let source = descriptor.make(makeContext())
        current = source
        source.start(into: self)
    }

    /// The user installed Jaca's CA on this capture's device.
    func caTrustChanged() {
        current?.caTrustChanged()
    }

    func relaunchToAttach() {
        (current as? IOSSimulatorAgentCaptureSource)?.relaunchToAttach()
    }

    func openBrowser() {
        (current as? MacBrowserCaptureSource)?.openBrowser()
    }

    func stop() {
        if state.isConnecting, !state.isRunning {
            // Cancel the launch that waits for its precheck.
            startGeneration &+= 1
            state.isConnecting = false
            return
        }
        guard state.isRunning else { return }
        state.isRunning = false
        state.proxyNeedsSetup = false
        state.attachState = .idle
        current?.stop()
        current = nil
    }

    func clearProxyNeedsSetup() { state.proxyNeedsSetup = false }
    func clear() {}
    func bodies(for id: UUID) async -> (req: Data?, resp: Data?)? { nil }   // in-process the tab holds them
    func harData() async -> Data? { HARExport.data(from: harSource?() ?? []) }

    func close() {
        stop()
        onTransactions = nil
        onState = nil
    }

    // MARK: - CaptureSink

    func capture(didReceive transaction: NetworkTransaction) {
        // Proof the CA is trusted only when the bytes came back decrypted with our CA: a
        // fabricated override never touched TLS, and the agent never uses the CA.
        // An unknown source proves nothing.
        let decrypted = currentDescriptor?.kind.decryptsWithOurCA ?? false
        if transaction.scheme == "https", transaction.error == nil, decrypted,
           !transaction.wasOverridden {
            state.caReady = true
            state.proxyNeedsSetup = false
        }
        onTransactions?([transaction])
    }

    func capture(didChangeAttach attach: InterceptArmingState) { state.attachState = attach }

    func capture(didChangeStatus status: String?) { state.statusMessage = status }
    func capture(didBindPort port: Int) { state.boundPort = port }
    func captureNeedsSetup() {
        if !state.caReady { state.proxyNeedsSetup = true }
    }
}
