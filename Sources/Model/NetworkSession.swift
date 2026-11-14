import Foundation
import Observation

/// One network-inspection tab. The user picks a capture source — in-process agent (one
/// debuggable app), companion (stream from the Jaca mobile agent), or any future one — from
/// `CaptureSourceRegistry`, and only then does capture start. The capture itself is a
/// `NetworkFeed`: an in-process `NetworkCaptureEngine`, or a capture running in `jacad` (daemon
/// mode, agent capture). This type is the view: the transaction list with body eviction,
/// selection, filtering, and the CA-install flow.
@MainActor
@Observable
final class NetworkSession: WorkspaceTab {
    let id: UUID
    var displayName: String { didSet { onStateChanged?() } }
    let device: Device

    var onStateChanged: (() -> Void)?
    var deviceContext: DeviceContext?

    private(set) var isRunning = false
    private(set) var isConnecting = false
    /// Whether the capture runs in `jacad` (daemon mode) rather than in-process.
    let isRemote: Bool
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
    var proxyNeedsSetup = false {
        didSet { if !proxyNeedsSetup, oldValue, feed.state.proxyNeedsSetup { feed.clearProxyNeedsSetup() } }
    }

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

    /// The shared response-override library — a reference to the one owner, never a copy.
    let overrides: OverridesModel?
    private let feed: NetworkFeed
    /// The daemon a remote tab sends CA installs to.
    private let daemon: DaemonConnector
    private var indexByID: [UUID: Int] = [:]
    private let bodyCache: NetworkBodyCache?
    private let bodiesInMemory = 1_000

    /// The source ids the capture side offers for this device under the current inspection mode,
    /// in chooser order. Mirrored from the feed state, so a mode switch re-renders the chooser.
    private(set) var offeredSourceIDs: [String] = []

    /// Capture options offered for this device, in display order. They come from the feed state
    /// (`offeredSourceIDs`), so a remote tab shows what `jacad` offers. Before the feed has
    /// reported any (a remote tab not yet opened), they come from the stored mode.
    var availableSources: [CaptureSourceDescriptor] {
        let offered = offeredSourceIDs.compactMap { CaptureSourceRegistry.descriptor(id: $0) }
        guard offered.isEmpty else { return offered }
        return CaptureSourceRegistry.options(for: device, context: deviceContext)
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
        case .mac:
            return nil                                            // this Mac captures through its browser
        }
    }

    /// Whether the toolbar's proxy "Setup" affordance is relevant: a proxy capture (the Android
    /// device proxy or the iOS Simulator system proxy) whose CA isn't confirmed yet. Companion and
    /// agent modes need no proxy/CA setup (the companion app installs the CA itself).
    var showsProxySetup: Bool { hasSelectedMode && captureMode == .proxy && proxyNeedsSetup }

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

    /// The proxy address the device uses. An adb device reaches the proxy over `adb reverse`, and
    /// an iOS Simulator runs on this Mac and uses its system proxy, so both use loopback (the
    /// simulator proxy binds 127.0.0.1 only).
    var hostAddress: String {
        isADBDevice || device.platform == .iosSimulator ? "127.0.0.1" : ProxyConfigurator.hostAddress(for: device)
    }

    /// The rows the list shows, **cached**.
    ///
    /// `body` reads this more than once per pass (the empty check and the `ForEach`) and SwiftUI
    /// re-runs `body` on every captured row, so the naive version was several case-insensitive
    /// scans of the whole capture per arriving transaction — cost that grows with the session and
    /// pegs the main thread after a few minutes of real traffic. Appends extend the cached array
    /// instead of rebuilding it; anything else (a new query, a time selection, a row rewritten in
    /// place) falls back to a full pass.
    var filtered: [NetworkTransaction] {
        // Reading `transactions` — not just the cache — is what registers the observation
        // dependency, so a new row still invalidates the view.
        let all = transactions
        let key = FilteredKey(stamp: filterStamp, count: all.count,
                              text: filterText, range: selectedTimeRange)
        if let cached = filteredCacheKey {
            if cached == key { return filteredCache }
            if cached.stamp == key.stamp, cached.text == key.text, cached.range == key.range,
               key.count > cached.count {
                for txn in all[cached.count...]
                where Self.matches(txn, query: key.text, range: key.range) {
                    filteredCache.append(txn)
                }
                filteredCacheKey = key
                return filteredCache
            }
        }
        filteredCache = all.filter { Self.matches($0, query: key.text, range: key.range) }
        filteredCacheKey = key
        return filteredCache
    }

    /// Pure, so the list predicate can be tested without a session.
    static func matches(_ txn: NetworkTransaction, query: String,
                        range: ClosedRange<Date>?) -> Bool {
        if let range {
            let end = txn.finishedAt ?? txn.startedAt
            if txn.startedAt > range.upperBound || end < range.lowerBound { return false }
        }
        if query.isEmpty { return true }
        return txn.url.range(of: query, options: .caseInsensitive) != nil
            || txn.host.range(of: query, options: .caseInsensitive) != nil
            || txn.method.range(of: query, options: .caseInsensitive) != nil
            // Companion rows carry the owning app here, so the filter doubles as a package filter.
            || txn.responseHeaders.contains { $0.name == "X-Jaca-App" && $0.value.range(of: query, options: .caseInsensitive) != nil }
    }

    /// What the cached `filtered` was computed from. `stamp` covers every change an append
    /// can't describe — a row rewritten in place, bodies spilled, a clear.
    private struct FilteredKey: Equatable {
        var stamp: UInt64
        var count: Int
        var text: String
        var range: ClosedRange<Date>?
    }

    @ObservationIgnored private var filterStamp: UInt64 = 0
    @ObservationIgnored private var filteredCache: [NetworkTransaction] = []
    @ObservationIgnored private var filteredCacheKey: FilteredKey?

    /// Call for any mutation of an existing row; appends must not, or the cache can never extend.
    private func invalidateFilterCache() {
        filterStamp &+= 1
    }

    /// The captured span, maintained as rows land instead of scanned per frame — the timeline
    /// asked for `min`/`max` over every transaction on every redraw.
    private(set) var earliestStart: Date?
    private(set) var latestEnd: Date?

    /// The timeline's x-axis domain, or nil before anything has been captured.
    var timeSpan: ClosedRange<Date>? {
        guard let earliestStart, let latestEnd else { return nil }
        return earliestStart...max(latestEnd, earliestStart.addingTimeInterval(1))
    }

    var selected: NetworkTransaction? {
        guard let selectedID, let idx = indexByID[selectedID] else { return nil }
        return transactions[idx]
    }

    /// An in-process capture (daemon mode off, HTTPS debugging, companion capture, and tests).
    convenience init(id: UUID = UUID(), device: Device, ca: CertificateAuthority, adbURL: URL?,
                     displayName: String? = nil, bodyCache: NetworkBodyCache? = nil,
                     companions: CompanionRegistry? = nil, overrides: OverridesModel? = nil) {
        var contextSource: (() -> DeviceContext?) = { nil }
        let engine = NetworkCaptureEngine(
            id: id, device: device, adbURL: adbURL, ca: ca, companion: companions?.hub,
            deviceContext: { contextSource() },
            interceptServices: { [weak overrides] in overrides?.localServices })
        self.init(id: id, device: device, feed: engine, ca: ca, adbURL: adbURL, displayName: displayName,
                  bodyCache: bodyCache, companions: companions, overrides: overrides, isRemote: false)
        contextSource = { [weak self] in self?.deviceContext }
        engine.harSource = { [weak self] in self?.transactions ?? [] }
    }

    /// A tab over any feed (an agent capture in `jacad`, in daemon mode).
    init(id: UUID, device: Device, feed: NetworkFeed, ca: CertificateAuthority, adbURL: URL?,
         displayName: String? = nil, bodyCache: NetworkBodyCache? = nil,
         companions: CompanionRegistry? = nil, overrides: OverridesModel? = nil, isRemote: Bool,
         daemon: DaemonConnector? = nil) {
        self.id = id
        self.daemon = daemon ?? .shared
        self.device = device
        self.feed = feed
        self.ca = ca
        self.adbURL = adbURL
        self.displayName = displayName ?? "Network · \(device.displayModel)"
        self.bodyCache = bodyCache
        self.companions = companions
        self.overrides = overrides
        self.isRemote = isRemote
        feed.onTransactions = { [weak self] in self?.receive($0) }
        feed.onState = { [weak self] in self?.apply($0) }
        apply(feed.state)
    }

    /// Mirrors the feed's capture state. The status message only follows the feed when the
    /// feed's own message changes, so a message the tab set itself (CA push) stays.
    private func apply(_ state: NetworkCaptureState) {
        let previous = lastFeedState
        lastFeedState = state
        isRunning = state.isRunning
        isConnecting = state.isConnecting
        if previous?.statusMessage != state.statusMessage { statusMessage = state.statusMessage }
        boundPort = state.boundPort
        if state.caReady, !caReady {
            caReady = true
            caInstaller?.noteInterceptionConfirmed()
        }
        if proxyNeedsSetup != state.proxyNeedsSetup { proxyNeedsSetup = state.proxyNeedsSetup }
        let modeChanged = selectedSourceID != state.selectedSourceID || hasSelectedMode != state.hasSelectedMode
            || targetPackage != state.targetPackage
        selectedSourceID = state.selectedSourceID
        hasSelectedMode = state.hasSelectedMode
        targetPackage = state.targetPackage
        if offeredSourceIDs != state.offeredSourceIDs { offeredSourceIDs = state.offeredSourceIDs }
        attachState = state.attachState
        interceptWired = state.interceptWired
        activeInterceptCapabilities = InterceptCapabilities(rawValue: state.interceptCapabilities)
        hasRunningSource = state.hasRunningSource
        if modeChanged { onStateChanged?() }
    }

    @ObservationIgnored private var lastFeedState: NetworkCaptureState?

    /// The in-process capture engine (the running source's `CaptureSink`), when the capture runs
    /// here rather than in `jacad`.
    var localEngine: NetworkCaptureEngine? { feed as? NetworkCaptureEngine }

    private func receive(_ batch: [NetworkTransaction]) {
        for txn in batch { upsert(txn) }
    }

    /// Takes over the rows and selection of the tab this one replaces (the capture moved between
    /// the app and `jacad`), so the user keeps what they captured.
    func adoptRows(_ rows: [NetworkTransaction], selectedID selected: UUID?) {
        // Rows captured by another source are no proof this tab's CA is trusted.
        adopting = true
        defer { adopting = false }
        for txn in rows { upsert(txn) }
        // Evicted bodies of these rows live in the other process's cache, which this tab can't
        // read: they stay evicted (shown as unavailable) instead of loading as empty.
        unreachableBodies.formUnion(rows.filter(\.bodiesEvicted).map(\.id))
        selectedID = selected
    }
    @ObservationIgnored private var adopting = false
    @ObservationIgnored private var unreachableBodies: Set<UUID> = []

    /// Restarts the running capture source so it picks up a changed intercept configuration
    /// (the source snapshots the override services at launch). Keeps the captured rows.
    func restartForInterceptChange() { feed.restartForInterceptChange() }

    /// Whether the device still has a proxy configured, including the per-network
    /// `global_http_proxy_*` rows a crashed session can strand — "connected, no internet".
    private(set) var deviceProxyLingers = false
    private(set) var isRevertingDeviceProxy = false

    /// Checks for a stranded device proxy. Cheap, and only meaningful for an adb device.
    func refreshDeviceProxyState() async {
        guard let adbURL, isADBDevice else { deviceProxyLingers = false; return }
        deviceProxyLingers = await ProxyConfigurator.hasAnyProxyConfigured(
            adbURL: adbURL, serial: device.id)
    }

    /// Clears every proxy key and re-validates the network, so a stranded device is recoverable
    /// without dropping to a shell.
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

    /// Whether this session wired up override services at launch — the toolbar must not claim
    /// overrides are active when nothing was armed.
    private(set) var interceptWired = false

    /// What the *running* capture source can honour, via the same clamp the runtime uses — so
    /// the toolbar tint and "can't run here" badge never promise what the transport won't do.
    private(set) var activeInterceptCapabilities: InterceptCapabilities = []

    /// Whether any capture source is running. With none, the honest message is "start capture",
    /// not "this rule can't run here".
    private(set) var hasRunningSource = false

    /// This tab's arming state, read from the one owner (`OverridesModel`) rather than copied.
    /// Toolbar, popover, row badge and attach banner all render this value.
    var armingState: InterceptArmingState {
        guard let overrides, let target = interceptTarget else { return attachState }
        let armed = overrides.arming(for: target)
        // With overrides off nothing publishes, so `.idle` means "nobody is arming", not "fine"
        // — fall back to what the source knows about the agent still being in the app.
        if case .idle = armed { return attachState }
        return armed
    }

    /// What the running source last reported about its agent. Separate from the coordinator's
    /// arming state because it must survive response overrides being off (HTTPS debugging mode).
    private(set) var attachState: InterceptArmingState = .idle

    /// Whether to show the pane-top attach notice: the agent is gone but the tab still believes
    /// it is capturing — the "armed and silently doing nothing" case.
    ///
    /// Gated on a running source, **not** on `interceptWired`: losing the agent kills capture
    /// either way, and only the simulator supervisor produces `.detached`/`.waitingForApp`.
    var showsAttachBanner: Bool {
        guard isRunning else { return false }
        switch armingState {
        case .detached, .waitingForApp: return true
        case .idle, .waitingForAgent, .agentTooOld, .active, .failed: return false
        }
    }

    /// The attach banner's action. Only the iOS-Simulator source can put the agent back, and only
    /// by relaunching the user's app — hence explicit, never automatic.
    func relaunchToAttach() { feed.relaunchToAttach() }

    /// This Mac: open the Chrome window again after the user closed it.
    func openBrowser() { feed.openBrowser() }

    /// The interception point this tab is currently capturing through. Before a source is
    /// chosen, the first offered one. With none, the companion transport, which applies no rule,
    /// so the UI never claims a rule fires.
    var interceptTransport: InterceptTransportID {
        // A mode switch reopens the chooser but keeps the old `selectedSourceID`; that source
        // may not exist in the new mode, so it counts only while a source is chosen.
        let chosen = hasSelectedMode ? selectedSourceID : nil
        guard let sourceID = chosen ?? availableSources.first?.id else { return .companionMetadata }
        return HTTPDebuggingStrategies.current.transport(device: device, sourceID: sourceID,
                                                         package: targetPackage)
    }

    // MARK: - Source selection (generic)

    /// Choose a capture source and start it. The single entry point for every source.
    func select(_ descriptor: CaptureSourceDescriptor, package: String? = nil) {
        statusMessage = nil   // a message the tab set itself (a CA push) belongs to the last run
        feed.select(sourceID: descriptor.id, package: package)
    }

    /// Restores the chosen source from persistence WITHOUT starting — a relaunched tab
    /// comes back pre-configured so the user just presses play. A kind the current mode doesn't
    /// offer for this device leaves the tab on the chooser.
    func restoreMode(_ mode: CaptureMode, package: String?) {
        guard let sourceID = availableSources.first(where: { $0.kind == mode })?.id else { return }
        feed.restoreMode(sourceID: sourceID, package: package)
    }

    /// Returns the tab to the chooser — the "switch source" escape hatch.
    func reopenModeChooser() { feed.reopenChooser() }

    /// Restart the chosen source — the toolbar play button after a stop.
    func resume() {
        statusMessage = nil
        feed.resume()
    }

    /// Starts the chosen source; a no-op while it already runs, as before the feed split.
    func start() {
        guard !isRunning, !isConnecting else { return }
        resume()
    }

    func stop() { feed.stop() }

    /// Ends the capture for good (the tab is closing).
    func close() { feed.close() }

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
        earliestStart = nil
        latestEnd = nil
        evictCursor = 0
        pendingEvictBytes = 0
        evictSoonTask?.cancel()
        evictSoonTask = nil
        invalidateFilterCache()
        feed.clear()
    }

    /// The capture as HAR (from the daemon in daemon mode, where the bodies are).
    func harData() async -> Data? { await feed.harData() }

    func upsert(_ txn: NetworkTransaction) {
        // First successfully MITM'd HTTPS request confirms the CA is trusted.
        //
        // Proof only when the bytes came back decrypted with our CA: a fabricated override never
        // touched TLS and the agent never uses the CA, so counting either would dismiss the setup
        // prompt for a user whose CA isn't installed. `== .proxy` was too narrow — companion
        // capture decrypts through `ProxyServer` too, so its CA sheet never saw `caReady` flip.
        if !adopting, txn.scheme == "https", txn.error == nil, captureMode.decryptsWithOurCA, !txn.wasOverridden {
            caReady = true
            proxyNeedsSetup = false
            caInstaller?.noteInterceptionConfirmed()
        }
        noteSpan(txn)
        if let idx = indexByID[txn.id] {
            transactions[idx] = txn
            invalidateFilterCache()
            // In daemon mode an update arrives without bodies; the row on screen fetches them again
            // (it would otherwise show an in-flight request's response as missing).
            if feed.bodiesOnDemand, txn.id == selectedID { ensureBodies(for: txn.id) }
        } else {
            indexByID[txn.id] = transactions.count
            transactions.append(txn)
            evictBodiesIfBacklogged()
        }
    }

    /// Keeps the timeline's domain up to date in O(1) per row.
    private func noteSpan(_ txn: NetworkTransaction) {
        if earliestStart == nil || txn.startedAt < earliestStart! { earliestStart = txn.startedAt }
        let end = txn.finishedAt ?? txn.startedAt
        if latestEnd == nil || end > latestEnd! { latestEnd = end }
    }

    /// Rows below this index have had their bodies spilled (or been considered for it).
    @ObservationIgnored private var evictCursor = 0
    /// Bytes still held by rows that have fallen out of the in-memory window.
    @ObservationIgnored private var pendingEvictBytes = 0
    @ObservationIgnored private var evictSoonTask: Task<Void, Never>?
    /// Spill in chunks, never one row at a time. Each spill rewrites rows in place, which
    /// re-renders the list and rebuilds the `filtered` cache — paying that per captured request
    /// doubled a busy capture's observable churn for no benefit.
    private let evictBatch = 200
    /// …but a chunk must never be allowed to hold much memory, which is the point of evicting.
    /// Whichever ceiling is hit first wins.
    private let evictByteBudget = 2 * 1024 * 1024

    private func evictBodiesIfBacklogged() {
        guard bodyCache != nil else { return }
        let limit = transactions.count - bodiesInMemory
        guard limit > evictCursor else { return }
        // Exactly one row falls out of the window per append once past it, so the running total
        // needs no scan.
        let newlyEligible = limit - 1
        if newlyEligible >= 0, newlyEligible < transactions.count {
            pendingEvictBytes += (transactions[newlyEligible].requestBody?.count ?? 0)
                + (transactions[newlyEligible].responseBody?.count ?? 0)
        }
        if limit - evictCursor >= evictBatch || pendingEvictBytes >= evictByteBudget {
            evictBodies(upTo: limit)
            return
        }
        scheduleTrailingEviction()
    }

    /// Drains a backlog too small to trigger a batch, so a capture that goes quiet just over the
    /// window still spills instead of holding those bodies for the life of the tab.
    private func scheduleTrailingEviction() {
        guard evictSoonTask == nil else { return }
        evictSoonTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.evictSoonTask = nil
            guard !Task.isCancelled else { return }
            self.evictBodies(upTo: self.transactions.count - self.bodiesInMemory)
        }
    }

    private func evictBodies(upTo limit: Int) {
        guard let cache = bodyCache, limit > evictCursor else { return }
        var blobs: [(UUID, Data?, Data?)] = []
        var stripped = false
        for index in evictCursor..<min(limit, transactions.count) where !transactions[index].bodiesEvicted {
            let txn = transactions[index]
            guard txn.requestBody != nil || txn.responseBody != nil else {
                transactions[index].bodiesEvicted = true
                stripped = true
                continue
            }
            blobs.append((txn.id, txn.requestBody, txn.responseBody))
        }
        evictCursor = min(limit, transactions.count)
        pendingEvictBytes = 0
        if stripped { invalidateFilterCache() }
        guard !blobs.isEmpty else { return }
        Task {
            for (id, req, resp) in blobs { await cache.save(id, req: req, resp: resp) }
            await MainActor.run { [weak self] in self?.stripBodies(blobs.map(\.0)) }
        }
    }

    /// One mutation for the whole batch, so the list re-renders once rather than per row.
    private func stripBodies(_ ids: [UUID]) {
        var changed = false
        for id in ids {
            guard let idx = indexByID[id] else { continue }
            transactions[idx].requestBody = nil
            transactions[idx].responseBody = nil
            transactions[idx].bodiesEvicted = true
            changed = true
        }
        if changed { invalidateFilterCache() }
    }

    /// The currently selected transaction, if any.
    var selectedTransaction: NetworkTransaction? {
        guard let selectedID, let idx = indexByID[selectedID] else { return nil }
        return transactions[idx]
    }

    /// Loads a transaction's bodies, **awaiting** the spill cache when they've been evicted.
    /// `ensureBodies(for:)` is fire-and-forget, which seeding can't use: the sheet must copy the
    /// body now, since `NetworkBodyCache` wipes its directory on every launch.
    func bodies(for id: UUID) async -> (req: Data?, resp: Data?) {
        guard let idx = indexByID[id] else { return (nil, nil) }
        let txn = transactions[idx]
        guard txn.bodiesEvicted else { return (txn.requestBody, txn.responseBody) }
        guard !unreachableBodies.contains(id) else { return (nil, nil) }
        let loaded: (req: Data?, resp: Data?)
        if feed.bodiesOnDemand {
            // In the daemon, which holds them. Unavailable (daemon gone, capture closed) keeps
            // the row evicted rather than recording an empty body.
            guard let fetched = await feed.bodies(for: id) else { return (nil, nil) }
            loaded = fetched
        } else if let cache = bodyCache {
            loaded = await cache.load(id)
        } else {
            return (txn.requestBody, txn.responseBody)
        }
        if let i = indexByID[id] {
            transactions[i].requestBody = loaded.req
            transactions[i].responseBody = loaded.resp
            transactions[i].bodiesEvicted = false
            invalidateFilterCache()
        }
        return (loaded.req, loaded.resp)
    }

    /// The latest body fetch per row: fetches can finish out of order, and an older one landing
    /// last would show stale bodies with nothing left to refetch.
    @ObservationIgnored private var bodyFetch: [UUID: Int] = [:]
    @ObservationIgnored private var bodyFetchCounter = 0

    func ensureBodies(for id: UUID) {
        guard let idx = indexByID[id], transactions[idx].bodiesEvicted, !unreachableBodies.contains(id),
              transactions[idx].requestBody == nil, transactions[idx].responseBody == nil else { return }
        let feed = self.feed, cache = bodyCache
        guard feed.bodiesOnDemand || cache != nil else { return }
        bodyFetchCounter &+= 1
        let fetch = bodyFetchCounter
        bodyFetch[id] = fetch
        Task {
            let fetched: (req: Data?, resp: Data?)?
            if feed.bodiesOnDemand {
                fetched = await feed.bodies(for: id)
            } else if let cache {
                fetched = await cache.load(id)
            } else {
                fetched = nil
            }
            await MainActor.run { [weak self] in
                guard let self, self.bodyFetch[id] == fetch else { return }
                self.bodyFetch[id] = nil
                // Unavailable: the row stays evicted.
                guard let bodies = fetched, let i = self.indexByID[id] else { return }
                self.transactions[i].requestBody = bodies.req
                self.transactions[i].responseBody = bodies.resp
                self.transactions[i].bodiesEvicted = false
                self.invalidateFilterCache()
            }
        }
    }

    /// A runnable `curl` for one transaction, rehydrating an evicted request body from the
    /// on-disk cache first — otherwise an older row would copy a command with its body missing.
    func curlCommand(for id: UUID) async -> String? {
        guard let idx = indexByID[id] else { return nil }
        var txn = transactions[idx]
        if txn.bodiesEvicted, txn.requestBody == nil, let cache = bodyCache {
            txn.requestBody = await cache.load(id).req
        }
        return CurlExport.command(for: txn)
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

    // MARK: - One-click CA install

    /// True while `installCA()` or `rebootSimulator()` runs.
    private(set) var isInstallingCA = false

    /// Installs Jaca's CA on this tab's device. Only a user action calls it.
    /// - iOS Simulator: adds the CA to the simulator keychain. Apps see it after a reboot
    ///   (`rebootAdvised`).
    /// - Android: installs into the system store when `adb root` works. Otherwise copies the CA
    ///   to Download and returns `needsUser`; the CA install sheet then guides the user.
    ///
    /// A remote tab asks `jacad` (`network.installCA`). An in-process tab runs the same steps here.
    /// Returns nil when the daemon can't be reached.
    func installCA() async -> NetworkArea.InstallCAResult? {
        guard !isInstallingCA else { return nil }
        isInstallingCA = true
        defer { isInstallingCA = false }
        if isRemote {
            do {
                return try await daemon.request("network.installCA", NetworkArea.IDParams(id: id),
                                                as: NetworkArea.InstallCAResult.self)
            } catch let error as RPCError {
                return NetworkArea.InstallCAResult(outcome: .failed, message: error.message)
            } catch {
                return NetworkArea.InstallCAResult(outcome: .failed, message: error.localizedDescription)
            }
        }
        let result = await Self.installCALocally(device: device, ca: ca, adbURL: adbURL, install: caInstall)
        // Hosts passed through before the install failed for want of the CA. Decrypt them again.
        if result.outcome == .installed { localEngine?.caTrustChanged() }
        return result
    }

    /// Reboots this tab's iOS Simulator, so its apps load a newly installed CA. Returns nil when
    /// the daemon can't be reached, or when an install or reboot already runs.
    func rebootSimulator() async -> Result<Void, SimulatorCAError>? {
        guard device.platform == .iosSimulator else {
            return .failure(SimulatorCAError(message: NetworkArea.rebootNotSimulatorMessage))
        }
        guard !isInstallingCA else { return nil }
        isInstallingCA = true
        defer { isInstallingCA = false }
        if isRemote {
            do {
                let done: RPCEmpty? = try await daemon.request("network.rebootSimulator",
                                                               NetworkArea.IDParams(id: id), as: RPCEmpty.self)
                return done == nil ? nil : .success(())
            } catch let error as RPCError {
                return .failure(SimulatorCAError(message: error.message))
            } catch {
                return .failure(SimulatorCAError(message: error.localizedDescription))
            }
        }
        let result = await caInstall.simulatorReboot(device.id)
        if case .success = result { localEngine?.caTrustChanged() }
        return result
    }

    /// The CA installers an in-process tab uses. Tests replace it.
    @ObservationIgnored var caInstall: NetworkCAInstall = .live

    /// The in-process copy of `NetworkArea.Captures.installCA`: same steps, same results.
    static func installCALocally(device: Device, ca: CertificateAuthority, adbURL: URL?,
                                 install: NetworkCAInstall) async -> NetworkArea.InstallCAResult {
        switch device.platform {
        case .iosSimulator:
            return NetworkArea.installCAResult(simulator: await install.simulatorInstall(device.id, ca.rootCertificatePEM))
        case .android where !device.isCompanion:
            guard let adbURL else {
                return NetworkArea.InstallCAResult(outcome: .failed, message: NetworkArea.adbMissingMessage)
            }
            let pem = FileManager.default.temporaryDirectory
                .appendingPathComponent("jaca-ca-\(UUID().uuidString.prefix(8)).pem")
            defer { try? FileManager.default.removeItem(at: pem) }
            do { try ca.exportRootCertificate(to: pem) } catch {
                JacaLog.error("proxy", "couldn't write the CA for \(device.id): \(error)")
                return NetworkArea.InstallCAResult(outcome: .failed, message: NetworkArea.noCAMessage)
            }
            let rooted = await install.androidRooted(adbURL, device.id, pem)
            var pushed: Bool?
            if rooted == .notRooted { pushed = await install.androidPush(adbURL, device.id, pem) }
            return NetworkArea.installCAResult(android: rooted, pushed: pushed)
        default:
            return NetworkArea.InstallCAResult(outcome: .failed, message: NetworkArea.installCAUnsupportedMessage)
        }
    }
}
