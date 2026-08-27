import Foundation
import Observation

/// One network-inspection tab. The user picks a capture source — proxy (device-wide
/// MITM), in-process agent (one debuggable Android app), companion (stream from the Jaca
/// mobile agent), or any future one — from `CaptureSourceRegistry`, and only then does
/// capture start. The session itself is generic: it runs whichever `CaptureSource` was
/// chosen and reacts to its events via `CaptureSink`, so adding a source touches nothing
/// here.
@MainActor
@Observable
final class NetworkSession: WorkspaceTab, CaptureSink {
    let id = UUID()
    var displayName: String { didSet { onStateChanged?() } }
    let device: Device

    var onStateChanged: (() -> Void)?
    var deviceContext: DeviceContext?

    private(set) var isRunning = false
    private(set) var isConnecting = false
    private(set) var transactions: [NetworkTransaction] = []
    var selectedID: UUID? {
        didSet { if let id = selectedID, id != oldValue { ensureBodies(for: id) } }
    }
    var filterText = ""
    var selectedTimeRange: ClosedRange<Date>?
    var statusMessage: String?
    private(set) var boundPort: Int = 0

    /// The live CA-install flow shown in `CAInstallSheet` (proxy mode).
    private(set) var caInstaller: AndroidCACertInstaller?
    /// Ground truth that the CA is trusted: flips true once a real HTTPS request is decrypted.
    private(set) var caReady = false
    /// Proxy started but the CA isn't confirmed — the view surfaces the setup dialog.
    var proxyNeedsSetup = false

    /// The chosen capture source (registry id), and whether the user has chosen one.
    private(set) var selectedSourceID: String?
    private(set) var hasSelectedMode = false
    /// Agent mode: the debuggable app to attach to. nil otherwise.
    var targetPackage: String?

    let ca: CertificateAuthority
    private let adbURL: URL?
    /// The single source of truth for companion link/capture state, and the transport the
    /// companion capture source streams from. Read reactively (via `companions.devices`) — no polling.
    let companions: CompanionRegistry?
    private var companion: CompanionHub? { companions?.hub }

    /// The shared response-override library. A reference to the one owner, never a copy — the
    /// views read `session.overrides` and re-render whenever it changes.
    let overrides: OverridesModel?
    private var current: CaptureSource?
    private var indexByID: [UUID: Int] = [:]
    private let bodyCache: NetworkBodyCache?
    private let bodiesInMemory = 1_000

    /// Capture options offered for this device (from the registry), in display order.
    var availableSources: [CaptureSourceDescriptor] {
        CaptureSourceRegistry.options(for: device, context: deviceContext)
    }
    /// The chosen source's descriptor (drives badge, subtitle, empty-state text).
    var currentDescriptor: CaptureSourceDescriptor? {
        selectedSourceID.flatMap { CaptureSourceRegistry.descriptor(id: $0) }
    }
    /// The chosen source kind, defaulting to proxy before a choice is made.
    var captureMode: CaptureMode { currentDescriptor?.kind ?? .proxy }

    /// In-process agent capture: Android (bundled .so/.dex) or the iOS Simulator (injected
    /// JacaNetAgent dylib) — no proxy/CA for either.
    var agentAvailable: Bool {
        (device.platform == .android && AgentArtifacts.isAvailable)
            || (device.platform == .iosSimulator && AgentArtifacts.iosNetworkAgentAvailable)
    }
    var isAndroid: Bool { device.platform == .android }

    /// Whether the experimental companion-capture feature is enabled (Settings →
    /// HTTPS decryption). When off the companion subsystem never starts, so its
    /// onboarding prompt ("install the Jaca mobile app…") must stay hidden.
    var companionCaptureEnabled: Bool { FeatureFlags.httpsDecryptionEnabled }

    /// A real ADB-connected Android device, not a companion-only entry. Proxy capture and
    /// adb-driven CA install only work here — a companion-only device has no adb path, so
    /// none of those apply to it.
    var isADBDevice: Bool { device.platform == .android && !device.isCompanion && adbURL != nil }

    /// Whether to offer the per-app in-process agent picker. True for a real ADB Android
    /// device (run-as attach) and for an iOS Simulator (DYLD-injected agent) when the agent
    /// is bundled — both pick one app to inspect in-process. A companion-only device has no
    /// agent path, so it's excluded. Replaces the old Android-only `isADBDevice` gate so the
    /// iOS-Simulator agent gets the picker too.
    var canPickAgentApp: Bool {
        guard agentAvailable else { return false }
        return isADBDevice || device.platform == .iosSimulator
    }

    /// Why the in-process agent isn't offered on a device that *should* support it — so the
    /// capture chooser can explain the absence instead of silently dropping the option (a
    /// missing agent must never look like "no capture modes at all"). `nil` when the agent
    /// is available, or when the device legitimately has no in-process path (a
    /// companion-only entry, or a physical iOS device — both use proxy/companion instead).
    var agentUnavailableReason: String? {
        guard !canPickAgentApp else { return nil }
        switch device.platform {
        case .android:
            if device.isCompanion { return nil }                  // companion-only: no adb path, by design
            if !AgentArtifacts.isAvailable { return AgentArtifacts.missingMessage }
            if adbURL == nil {
                return """
                    Android platform-tools weren’t found, so Jaca can’t attach the in-process \
                    agent over adb. Install the Android SDK platform-tools and make sure `adb` \
                    is on your PATH, then relaunch Jaca.
                    """
            }
            return nil
        case .iosSimulator:
            return AgentArtifacts.iosNetworkAgentAvailable ? nil : AgentArtifacts.iosMissingMessage
        case .iosDevice:
            return nil                                            // no in-process attach on a real device
        }
    }

    /// Whether the toolbar's proxy "Setup" affordance is relevant: only for a real ADB
    /// device actively capturing via the MITM proxy. Companion and agent modes need no
    /// proxy/CA setup (the companion app installs the CA itself), so it's hidden there.
    var showsProxySetup: Bool { isADBDevice && hasSelectedMode && captureMode == .proxy }

    /// The companion stream id for this device.
    var companionID: String { device.companionID ?? device.id }
    /// Whether the companion gRPC link is connected right now. Read from the shared registry
    /// (observable), so any view that reads it re-renders the moment it changes — no polling,
    /// no stale Device snapshot.
    var companionLinked: Bool { companions?.state(for: companionID)?.connected ?? false }
    /// Whether the on-device VPN capture is actually running (from the device heartbeat) — so
    /// the desktop can say "VPN not running" and notice when the user stops capture.
    var deviceCapturing: Bool { companions?.state(for: companionID)?.capturing ?? false }
    /// macOS is blocking mDNS discovery (Local Network permission) — drives the guided sheet's
    /// "allow Local Network" hint. Shared with the sidebar's notice (one source of truth).
    var companionNetworkBlocked: Bool { companions?.networkBlocked ?? false }
    /// One-shot guard so the guided companion setup sheet auto-presents once per session
    /// (when opened and not yet decrypting), not on every tab switch.
    var didAutoShowCompanionSetup = false

    var subtitle: String {
        var parts = [device.displayModel]
        if let d = currentDescriptor { parts.append(d.label) }
        if captureMode == .proxy, boundPort > 0 { parts.append(":\(boundPort)") }
        if captureMode == .agent, let p = targetPackage, !p.isEmpty { parts.append(p) }
        if !isRunning { parts.append("stopped") }
        return parts.joined(separator: " · ")
    }

    var hostAddress: String { ProxyConfigurator.hostAddress(for: device) }

    var filtered: [NetworkTransaction] {
        let q = filterText
        return transactions.filter { txn in
            if let range = selectedTimeRange {
                let end = txn.finishedAt ?? txn.startedAt
                if txn.startedAt > range.upperBound || end < range.lowerBound { return false }
            }
            if q.isEmpty { return true }
            return txn.url.range(of: q, options: .caseInsensitive) != nil
                || txn.host.range(of: q, options: .caseInsensitive) != nil
                || txn.method.range(of: q, options: .caseInsensitive) != nil
                // Companion rows carry the owning app here, so the filter doubles as a package filter.
                || txn.responseHeaders.contains { $0.name == "X-Jaca-App" && $0.value.range(of: q, options: .caseInsensitive) != nil }
        }
    }

    var selected: NetworkTransaction? {
        guard let selectedID, let idx = indexByID[selectedID] else { return nil }
        return transactions[idx]
    }

    init(device: Device, ca: CertificateAuthority, adbURL: URL?, displayName: String? = nil,
         bodyCache: NetworkBodyCache? = nil, companions: CompanionRegistry? = nil,
         overrides: OverridesModel? = nil) {
        self.device = device
        self.ca = ca
        self.adbURL = adbURL
        self.displayName = displayName ?? "Network · \(device.displayModel)"
        self.bodyCache = bodyCache
        self.companions = companions
        self.overrides = overrides
    }

    /// Restarts the running capture source so it picks up a changed intercept configuration.
    ///
    /// `makeContext()` snapshots the override services at launch, so a flag toggled mid-capture
    /// only takes effect on the next launch. Re-selecting the same source is the cheapest honest
    /// way to apply it, and it keeps the captured rows.
    func restartForInterceptChange() {
        guard isRunning, let descriptor = currentDescriptor else { return }
        current?.stop()
        current = nil
        let source = descriptor.make(makeContext())
        current = source
        source.start(into: self)
    }

    /// Whether this device still has a proxy configured — including the per-network
    /// `global_http_proxy_*` rows that a crashed session can strand, leaving the device
    /// "connected, no internet" long after Jaca exited.
    private(set) var deviceProxyLingers = false
    private(set) var isRevertingDeviceProxy = false

    /// Checks for a stranded device proxy. Cheap, and only meaningful for an adb device.
    func refreshDeviceProxyState() async {
        guard let adbURL, isADBDevice else { deviceProxyLingers = false; return }
        deviceProxyLingers = await ProxyConfigurator.hasAnyProxyConfigured(
            adbURL: adbURL, serial: device.id)
    }

    /// Clears every proxy key and re-validates the network, so a device stranded by a crashed
    /// session can be recovered without dropping to a shell.
    func revertDeviceProxy() async {
        guard let adbURL, isADBDevice, !isRevertingDeviceProxy else { return }
        isRevertingDeviceProxy = true
        JacaLog.info("proxy", "reverting device proxy on \(device.id)")
        await ProxyConfigurator.clearAndroidProxy(adbURL: adbURL, serial: device.id)
        ProxyCleanup.deregister(adbPath: adbURL.path, serial: device.id)
        await refreshDeviceProxyState()
        isRevertingDeviceProxy = false
        JacaLog.info("proxy",
            "device proxy revert finished on \(device.id); stillConfigured=\(deviceProxyLingers)")
    }

    /// This tab's arming target, when it's inspecting one app on one device.
    var interceptTarget: InterceptTarget? {
        guard let package = targetPackage, !package.isEmpty else { return nil }
        return InterceptTarget(deviceID: device.id, package: package)
    }

    /// Whether this session actually wired up override services when it launched. The toolbar
    /// must not claim overrides are active when nothing was armed.
    var interceptWired: Bool { current?.arming != nil }

    /// What the *currently running* capture source can honour when a rule matches. Drives the
    /// toolbar tint and the "matches but can't run here" badge, using the same clamp the runtime
    /// uses, so the UI can never promise something the transport won't do.
    var activeInterceptCapabilities: InterceptCapabilities {
        current?.interceptCapabilities ?? []
    }

    /// Whether a capture source is running at all. With none, "this rule can't run here" is
    /// misleading — the honest message is "start capture".
    var hasRunningSource: Bool { current != nil }

    /// The interception point this tab is currently capturing through.
    var interceptTransport: InterceptTransportID {
        switch captureMode {
        case .agent:
            return device.platform == .iosSimulator
                ? .iosSimulatorDivert(bundleID: targetPackage ?? "")
                : .agentDivert(package: targetPackage ?? "")
        case .companion:
            return .companionMetadata
        default:
            return .mitmProxy
        }
    }

    // MARK: - Source selection (generic)

    /// Choose a capture source and start it. The single entry point for every source.
    func select(_ descriptor: CaptureSourceDescriptor, package: String? = nil) {
        if isRunning { stop() }
        targetPackage = descriptor.needsPackage ? package : nil
        selectedSourceID = descriptor.id
        hasSelectedMode = true
        onStateChanged?()
        start()
    }

    /// Restores the chosen source from persistence WITHOUT starting — a relaunched tab
    /// comes back pre-configured so the user just presses play.
    func restoreMode(_ mode: CaptureMode, package: String?) {
        selectedSourceID = CaptureSourceRegistry.all.first { $0.kind == mode }?.id
        targetPackage = (mode == .agent) ? package : nil
        hasSelectedMode = true
    }

    /// Returns the tab to the chooser — the "switch source" escape hatch.
    func reopenModeChooser() {
        if isRunning { stop() }
        hasSelectedMode = false
        proxyNeedsSetup = false
    }

    /// Restart the chosen source — the toolbar play button after a stop.
    func resume() {
        guard hasSelectedMode, let descriptor = currentDescriptor else { return }
        select(descriptor, package: targetPackage)
    }

    func start() {
        guard !isRunning, !isConnecting, hasSelectedMode, let descriptor = currentDescriptor else { return }
        statusMessage = nil
        guard let precheck = descriptor.precheck else { launch(descriptor); return }
        // A source that needs the device reachable (agent) verifies first and surfaces a
        // clear message instead of silently failing.
        isConnecting = true
        Task { @MainActor in
            let error = await precheck(makeContext())
            isConnecting = false
            if let error { statusMessage = error; return }
            launch(descriptor)
        }
    }

    private func launch(_ descriptor: CaptureSourceDescriptor) {
        guard !isRunning else { return }
        isRunning = true
        let source = descriptor.make(makeContext())
        current = source
        source.start(into: self)
    }

    private func makeContext() -> CaptureContext {
        CaptureContext(device: device, adbURL: adbURL, ca: ca, deviceContext: deviceContext,
                       targetPackage: targetPackage, companion: companion,
                       intercept: FeatureFlags.responseOverridesEnabled ? overrides?.services() : nil)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        proxyNeedsSetup = false
        current?.stop()
        current = nil
    }

    func toggle() { isRunning ? stop() : resume() }

    // MARK: - Convenience wrappers (used by the chooser + app picker)

    func startAgentCapture(package: String) {
        guard let d = CaptureSourceRegistry.descriptor(id: "agent") else { return }
        select(d, package: package)
    }

    func startCompanionCapture() {
        guard let d = CaptureSourceRegistry.descriptor(id: "companion") else { return }
        select(d)
    }

    /// Choose what to capture: a specific app (agent) or the whole device (companion).
    func setTarget(_ package: String?) {
        if let pkg = package, !pkg.isEmpty { startAgentCapture(package: pkg) } else { startCompanionCapture() }
    }

    // MARK: - CaptureSink (events from the running source)

    func capture(didReceive transaction: NetworkTransaction) { upsert(transaction) }
    func capture(didChangeStatus status: String?) { statusMessage = status }
    func capture(didBindPort port: Int) { boundPort = port }
    func captureNeedsSetup() {
        if !caReady { proxyNeedsSetup = true }
    }

    // MARK: - Apps (agent target picker)

    func installedApps() async -> [AppEntry] { await InstalledApps.list(for: device, adbURL: adbURL) }

    func isDebuggable(_ package: String) async -> Bool {
        guard let adbURL, device.platform == .android else { return false }
        return await AgentController.isDebuggable(adbURL: adbURL, serial: device.id, package: package)
    }

    func clear() {
        transactions.removeAll(keepingCapacity: true)
        indexByID.removeAll(keepingCapacity: true)
        selectedID = nil
        selectedTimeRange = nil
    }

    func upsert(_ txn: NetworkTransaction) {
        // First successfully MITM'd HTTPS request confirms the CA is trusted.
        //
        // This is proof only when the bytes actually came back through the proxy: a response an
        // override fabricated never touched TLS, and the agent doesn't use the CA at all, so
        // neither says anything about whether the device trusts it. Counting those would dismiss
        // the CA-setup prompt for a user whose CA isn't installed.
        if txn.scheme == "https", txn.error == nil, captureMode == .proxy, !wasOverridden(txn) {
            caReady = true
            proxyNeedsSetup = false
            caInstaller?.noteInterceptionConfirmed()
        }
        if let idx = indexByID[txn.id] {
            transactions[idx] = txn
        } else {
            indexByID[txn.id] = transactions.count
            transactions.append(txn)
            if transactions.count > bodiesInMemory {
                evictBodies(at: transactions.count - bodiesInMemory - 1)
            }
        }
    }

    private func evictBodies(at index: Int) {
        guard let cache = bodyCache,
              index >= 0, index < transactions.count, !transactions[index].bodiesEvicted else { return }
        let txn = transactions[index]
        guard txn.requestBody != nil || txn.responseBody != nil else {
            transactions[index].bodiesEvicted = true; return
        }
        let id = txn.id, req = txn.requestBody, resp = txn.responseBody
        Task {
            await cache.save(id, req: req, resp: resp)
            await MainActor.run { [weak self] in self?.stripBodies(id) }
        }
    }

    private func stripBodies(_ id: UUID) {
        guard let idx = indexByID[id] else { return }
        transactions[idx].requestBody = nil
        transactions[idx].responseBody = nil
        transactions[idx].bodiesEvicted = true
    }

    /// True when a rule produced this response, so it can't be treated as evidence about the
    /// network (it never reached one). Read from the stamp the pipeline puts on the response.
    private func wasOverridden(_ txn: NetworkTransaction) -> Bool {
        txn.responseHeaders.contains { $0.name.lowercased() == OverrideHeaders.override.lowercased() }
    }

    /// The currently selected transaction, if any.
    var selectedTransaction: NetworkTransaction? {
        guard let selectedID, let idx = indexByID[selectedID] else { return nil }
        return transactions[idx]
    }

    /// Loads a transaction's bodies, **awaiting** the spill cache when they've been evicted.
    ///
    /// `ensureBodies(for:)` is fire-and-forget (it feeds the detail pane, which can repaint when
    /// the bodies land). Seeding an override rule can't work that way: the sheet has to copy the
    /// body at creation time, because `NetworkBodyCache` wipes its directory on every launch, so a
    /// rule that didn't snapshot its payload could never recover it.
    func bodies(for id: UUID) async -> (req: Data?, resp: Data?) {
        guard let idx = indexByID[id] else { return (nil, nil) }
        let txn = transactions[idx]
        if !txn.bodiesEvicted || bodyCache == nil { return (txn.requestBody, txn.responseBody) }
        guard let cache = bodyCache else { return (txn.requestBody, txn.responseBody) }
        let loaded = await cache.load(id)
        if let i = indexByID[id] {
            transactions[i].requestBody = loaded.req
            transactions[i].responseBody = loaded.resp
            transactions[i].bodiesEvicted = false
        }
        return (loaded.req, loaded.resp)
    }

    func ensureBodies(for id: UUID) {
        guard let idx = indexByID[id], transactions[idx].bodiesEvicted,
              transactions[idx].requestBody == nil, transactions[idx].responseBody == nil,
              let cache = bodyCache else { return }
        Task {
            let bodies = await cache.load(id)
            await MainActor.run { [weak self] in
                guard let self, let i = self.indexByID[id] else { return }
                self.transactions[i].requestBody = bodies.req
                self.transactions[i].responseBody = bodies.resp
                self.transactions[i].bodiesEvicted = false
            }
        }
    }

    // MARK: - CA (proxy mode)

    func pushCAToDevice() {
        guard device.platform == .android, let adbURL else { return }
        let serial = device.id
        let caURL = ca.storageDirectory.appendingPathComponent("rootCA.pem")
        Task {
            let ok = await ProxyConfigurator.pushCACertToAndroid(adbURL: adbURL, serial: serial, caPEM: caURL)
            await MainActor.run {
                statusMessage = ok
                    ? "CA pushed to /sdcard/Download/JacaProxyCA.pem — install it in Settings."
                    : "Failed to push CA certificate."
            }
        }
    }

    func prepareCAInstall() async {
        guard device.platform == .android, let adbURL else { return }
        let caURL = ca.storageDirectory.appendingPathComponent("rootCA.pem")
        let caps: AndroidCapabilities
        if let cached = deviceContext?.capabilities { caps = cached }
        else { caps = await AndroidCapabilityProbe.probe(adbURL: adbURL, serial: device.id) }
        caInstaller = AndroidCACertInstaller(adbURL: adbURL, serial: device.id, caPEM: caURL, capabilities: caps)
    }

    func cancelCAInstall() {
        caInstaller?.cancel()
        if isRunning { stop() }
    }
}
