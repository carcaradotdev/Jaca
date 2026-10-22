import Foundation
import Observation

/// The top-level areas of the app.
enum WorkspaceMode: String { case devices, projects, gradle, xcode, cloudLogging }

/// Root app state: the merged live device list and the ordered set of log
/// sessions (tabs). Providers are pluggable, so iOS slots in by appending another
/// `DeviceProvider` and a matching `LogSource` in `startSession`.
@MainActor
@Observable
final class AppModel {
    private(set) var devices: [Device] = []
    private(set) var sessions: [any WorkspaceTab] = []
    var selectedSessionID: UUID?

    /// Top-level area the app is showing: the device/session view or the worktrees area.
    var mode: WorkspaceMode = .devices

    /// Experimental HTTPS decryption + companion capture, OFF by default and fully opt-in
    /// (Settings). When off, the companion subsystem is never started and network inspection
    /// offers only Agent mode (per-app, in-process, no CA). Persisted across launches.
    var httpsDecryptionEnabled: Bool = FeatureFlags.httpsDecryptionEnabled {
        didSet {
            guard httpsDecryptionEnabled != oldValue else { return }
            FeatureFlags.httpsDecryptionEnabled = httpsDecryptionEnabled
            reconfigureCompanion()
        }
    }

    /// The unified Projects area state: auto-detected Claude projects + user-added
    /// folders, their worktrees, and per-checkout cache cleanup.
    let projects = ProjectsModel()

    /// The Gradle daemons area state (lists/kills running Gradle daemons).
    let gradle = GradleDaemonsModel()

    /// The Xcode DerivedData area state (lists/deletes build caches; flags stale ones).
    let xcode = DerivedDataModel()

    /// The Cloud Logging area state — the single source of truth for gcloud detection/auth,
    /// the configured GCP projects, and each project's global log-name/label state. Read by
    /// every `CloudLogSession` so changes (e.g. switching log name) propagate to all its tabs.
    let cloudLogging = CloudLoggingRegistry()

    /// Resolved adb path; nil means the toolchain wasn't found (surface in UI).
    private(set) var adbURL: URL?

    /// Persistent log history (nil only if the DB couldn't be opened).
    let history: HistoryStore?

    /// History retention; sessions older than this are pruned on launch.
    var retention: TimeInterval = 7 * 24 * 60 * 60

    var selectedSession: (any WorkspaceTab)? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    private var providers: [DeviceProvider] = []
    private var discoveryTasks: [Task<Void, Never>] = []
    private var devicesByPlatform: [DevicePlatform: [Device]] = [:]

    /// The single source of truth for companion devices — mDNS discovery, the gRPC control
    /// links, CA push, capture heartbeats, and the blocked-network hint. Every flow reads this
    /// (no per-screen polling or duplicated validation); the device list folds its `devices`
    /// in below, and network sessions read link/capture state straight from it.
    private(set) var companions: CompanionRegistry!
    /// QR / web / adb onboarding for connecting a new device (set in init).
    private(set) var companionSetup: CompanionSetupModel!

    /// Per-device shared state (capabilities + installed-app polling), one per
    /// `Device.id`, reused by every tab for that device. Created with the first
    /// tab and torn down when the last tab for a device closes.
    private var deviceContexts: [String: DeviceContext] = [:]

    /// Tabs persisted from a previous launch, restored as their devices appear.
    private var pendingRestores: [TabDescriptor] = []
    private var isRestoring = false
    private static let tabsKey = "openTabs"
    /// Clean, isolated state for UI tests (no restore, no persistence pollution).
    private let uiTestMode = ProcessInfo.processInfo.environment["JACA_UITEST"] == "1"
    /// UI-test hook: auto-open a session for the first ready device of this
    /// platform (works around macOS not delivering content clicks to an inactive
    /// test window). Value is a DevicePlatform rawValue.
    private let autoSessionPlatform = ProcessInfo.processInfo.environment["JACA_AUTO_SESSION"]
        .flatMap { DevicePlatform(rawValue: $0) }

    init() {
        history = HistoryStore()
        if let days = UserDefaults.standard.object(forKey: "retentionDays") as? Int, days > 0 {
            retention = TimeInterval(days) * 86_400
        }
        if !uiTestMode {
            pendingRestores = Self.loadPersistedTabs()
        }
        buildProviders()
        companions = CompanionRegistry(ca: { [weak self] in self?.ensureCA() },
                                       adbURL: { [weak self] in self?.adbURL },
                                       uiTestMode: uiTestMode)
        // Fold companion devices into the unified list, and let the registry know when a
        // companion is "expected" (a capture tab is open) so it can widen the blocked hint.
        companions.onChange = { [weak self] in self?.recomputeDevices() }
        companions.hasOpenCompanionSession = { [weak self] in
            self?.sessions.contains { ($0 as? NetworkSession)?.captureMode == .companion } ?? false
        }
        companionSetup = CompanionSetupModel(hub: companions.hub, adbURL: adbURL)
        // Push global message-exclusion edits to every open log tab, live.
        LogExclusionStore.shared.onChange = { [weak self] in
            guard let self else { return }
            let rules = LogExclusionStore.shared.rules
            for case let session as LogSession in self.sessions { session.applyExclusions(rules) }
        }
        // Restore now: Cloud Logging tabs (no device) come back immediately; device-backed tabs
        // stay pending until their device reappears. Anything not yet restorable is KEPT pending
        // (never dropped), so a transient failure — e.g. projects not loaded yet — can't erase it.
        restorePendingTabs()
        let store = history
        let cutoff = Date().addingTimeInterval(-retention)
        Task { await store?.prune(olderThan: cutoff) }
    }

    private func buildProviders() {
        adbURL = AndroidToolchain.adbURL(override: UserDefaults.standard.string(forKey: "adbPath"))
        providers = []
        if let adbURL {
            providers.append(AndroidDeviceProvider(adbURL: adbURL))
        }
        providers.append(SimulatorDeviceProvider())   // self-guards when no Xcode
        providers.append(IOSDeviceProvider())          // self-guards when no devicectl
    }

    /// Re-resolves the toolchain (e.g. after the adb path changes in Settings)
    /// and restarts discovery.
    func reloadProviders() {
        discoveryTasks.forEach { $0.cancel() }
        discoveryTasks.removeAll()
        devicesByPlatform.removeAll()
        devices = []
        buildProviders()
        startDiscovery()
    }

    // MARK: - Discovery

    func startDiscovery() {
        guard discoveryTasks.isEmpty else { return }
        for provider in providers {
            let platform = provider.platform
            let task = Task { [weak self] in
                for await list in provider.deviceStream() {
                    guard let self else { return }
                    self.devicesByPlatform[platform] = list
                    // Feed adb-connected Android devices to the registry (only when the
                    // experimental feature is on) so it can discover their companion IP.
                    if platform == .android, !self.uiTestMode, self.httpsDecryptionEnabled {
                        self.companions.setADBCompanionDevices(
                            list.filter { $0.state.isReady }.map { (serial: $0.id, model: $0.model) })
                    }
                    self.recomputeDevices()
                }
            }
            discoveryTasks.append(task)
        }
        // Companion discovery is owned by `companions` (the single source of truth). It folds
        // its devices into the list via the `onChange` wired in init. Started only when the
        // experimental HTTPS-decryption feature is on — otherwise the companion subsystem never
        // initializes and network inspection stays Agent-only.
        if !uiTestMode && httpsDecryptionEnabled { companions.start() }
    }

    /// Start or tear down the companion subsystem when the feature flag toggles at runtime.
    private func reconfigureCompanion() {
        if httpsDecryptionEnabled {
            companions.start()
            if let android = devicesByPlatform[.android] {
                companions.setADBCompanionDevices(
                    android.filter { $0.state.isReady }.map { (serial: $0.id, model: $0.model) })
            }
        } else {
            companions.stop()
        }
        recomputeDevices()
    }

    /// Normalized device model, for matching a companion ("Jaca <MODEL>") to its adb device.
    private static func normalizedModel(_ s: String) -> String {
        s.replacingOccurrences(of: "Jaca", with: "").lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Match a companion advertisement ("Jaca <MODEL>") to an adb device by model name.
    private static func companionMatches(_ companionName: String, _ device: Device) -> Bool {
        guard device.platform == .android, !device.isCompanion else { return false }
        let n = normalizedModel(companionName), m = normalizedModel(device.model)
        return !m.isEmpty && !n.isEmpty && (n.contains(m) || m.contains(n))
    }

    private func recomputeDevices() {
        var merged = devicesByPlatform
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { $0.value }

        // Companion is just another device source (owned by `companions`), but only when the
        // experimental HTTPS-decryption feature is on. Off (the default) → no companion devices
        // or annotations at all; the list is plain adb/iOS devices captured via the Agent.
        if httpsDecryptionEnabled {
            // Each phone is ONE row: an adb device's row is annotated with its companion link —
            // preferring the stable USB link, else a matching mDNS link for the same model — so
            // the same phone is never duplicated or shown "offline" next to its live adb row.
            // Companions with no adb device of their own surface as their own entries.
            let companionStates = companions.devices
            let adbComps = companionStates.filter { $0.transport == .adb }
            let netComps = companionStates.filter { $0.transport != .adb }   // mDNS / manual
            var matchedNetIDs = Set<String>()

            for i in merged.indices where merged[i].platform == .android && !merged[i].isCompanion {
                let rawAdb = adbComps.first { $0.id == "adb:" + merged[i].id }
                // An adb forward only counts as a companion once the app has actually answered
                // over it (connected now, or seen before — `version` is set by Describe).
                let adb = (rawAdb?.connected == true || rawAdb?.version != nil) ? rawAdb : nil
                let net = netComps.first { Self.companionMatches($0.name, merged[i]) }
                if let net { matchedNetIDs.insert(net.id) }
                // Prefer whichever link is actually up, biased to USB; otherwise keep the adb id
                // so a just-plugged phone still reads as a companion while the link settles.
                let link = (adb?.connected == true ? adb : nil)
                    ?? (net?.connected == true ? net : nil)
                    ?? adb ?? net
                if let link {
                    merged[i].companionID = link.id
                    merged[i].companionConnected = link.connected
                    merged[i].companionUpdateAvailable = link.updateAvailable
                }
            }

            // Companions with no adb device of their own: their own entries.
            for comp in netComps where !matchedNetIDs.contains(comp.id) {
                var device = Device(id: comp.id, platform: .android, model: comp.name,
                                    state: comp.connected ? .connected : .offline,
                                    isCompanion: true, companionID: comp.id, companionConnected: comp.connected)
                device.companionUpdateAvailable = comp.updateAvailable
                merged.append(device)
            }
        }

        devices = merged
        restorePendingTabs()

        if let platform = autoSessionPlatform, sessions.isEmpty,
           let device = devices.first(where: { $0.platform == platform && $0.state.isReady }) {
            startSession(for: device)
        }
    }

    // MARK: - Tab persistence & restore

    private func restorePendingTabs() {
        guard !pendingRestores.isEmpty else { return }
        var stillPending: [TabDescriptor] = []
        isRestoring = true
        for descriptor in pendingRestores {
            // Cloud Logging tabs have no device — they only need their project loaded. Keep them
            // pending (never drop) until it is, so a transient project-load failure can't lose them.
            if descriptor.kind == .cloud {
                if let projectID = descriptor.projectID, cloudLogging.project(projectID) != nil {
                    startCloudLogSession(
                        projectID: projectID, autoStart: false, displayName: descriptor.displayName,
                        query: descriptor.cloudQuery ?? CloudLogQuery(),
                        timeRange: descriptor.cloudTimeRange ?? .last(minutes: 15),
                        rawFilter: descriptor.cloudRawFilter)
                } else {
                    stillPending.append(descriptor)
                }
                continue
            }
            guard let device = devices.first(where: {
                $0.id == descriptor.deviceID && $0.platform == descriptor.platform && $0.state.isReady
            }) else {
                stillPending.append(descriptor)
                continue
            }
            // Restore tabs STOPPED — the user presses play to stream — so a relaunch
            // never starts many sessions at once (which can overwhelm the app).
            switch descriptor.kind {
            case .log:
                var filter = LogFilter()
                filter.minLevel = LogLevel(rawValue: descriptor.minLevel) ?? .verbose
                filter.query = descriptor.query
                filter.isRegex = descriptor.isRegex
                let session = startSession(for: device, filter: filter, name: descriptor.displayName, autoStart: false)
                if !descriptor.packageLabel.isEmpty { session?.setPackage(descriptor.packageLabel) }
            case .network:
                let session = startNetworkSession(for: device, name: descriptor.displayName, autoStart: false)
                // Pre-configure the chosen mode so the tab restores ready-to-run:
                // the user just presses play (no re-picking from the chooser).
                let pkg = descriptor.packageLabel.isEmpty ? nil : descriptor.packageLabel
                let kind = descriptor.captureMode.flatMap { CaptureSourceRegistry.descriptor(id: $0)?.kind } ?? .proxy
                session?.restoreMode(kind, package: pkg)
            case .cloud:
                break   // Cloud Logging tabs have no device; restored eagerly in `restoreCloudTabs`.
            }
        }
        isRestoring = false
        pendingRestores = stillPending
        persistTabs()
    }

    /// Serializes open tabs (plus not-yet-restored ones) for the next launch.
    func persistTabs() {
        guard !isRestoring, !uiTestMode else { return }
        var descriptors = sessions.compactMap { Self.descriptor(for: $0) }
        // Keep tabs whose device hasn't reappeared yet so they survive a relaunch.
        for pending in pendingRestores where !descriptors.contains(where: { $0.matches(pending) }) {
            descriptors.append(pending)
        }
        if let data = try? JSONEncoder().encode(descriptors) {
            UserDefaults.standard.set(data, forKey: Self.tabsKey)
        }
    }

    private static func descriptor(for tab: any WorkspaceTab) -> TabDescriptor? {
        if let log = tab as? LogSession {
            return TabDescriptor(kind: .log, platform: log.device.platform, deviceID: log.device.id,
                                 displayName: log.displayName, minLevel: log.filter.minLevel.rawValue,
                                 query: log.filter.query, isRegex: log.filter.isRegex,
                                 packageLabel: log.filter.packageLabel)
        }
        if let net = tab as? NetworkSession {
            return TabDescriptor(kind: .network, platform: net.device.platform, deviceID: net.device.id,
                                 displayName: net.displayName, minLevel: 0, query: "",
                                 isRegex: false, packageLabel: net.targetPackage ?? "",
                                 captureMode: net.currentDescriptor?.id ?? "proxy")
        }
        if let cloud = tab as? CloudLogSession {
            return TabDescriptor(kind: .cloud, platform: .android, deviceID: "",
                                 displayName: cloud.displayName, minLevel: 0, query: "",
                                 isRegex: false, packageLabel: "",
                                 projectID: cloud.projectID, cloudQuery: cloud.query,
                                 cloudTimeRange: cloud.timeRange, cloudRawFilter: cloud.rawFilter)
        }
        return nil
    }

    private static func loadPersistedTabs() -> [TabDescriptor] {
        guard let data = UserDefaults.standard.data(forKey: tabsKey) else { return [] }
        // Tolerant + element-by-element: one unreadable tab can't drop all the others.
        return CloudPersistence.decodeArray(TabDescriptor.self, from: data)
    }

    // MARK: - Per-device shared context

    /// Vends the shared `DeviceContext` for `device`, creating + starting it on
    /// first use. Reused across all tabs targeting the same device.
    private func context(for device: Device) -> DeviceContext {
        if let existing = deviceContexts[device.id] { return existing }
        let ctx = DeviceContext(device: device, adbURL: adbURL)
        deviceContexts[device.id] = ctx
        ctx.start()
        return ctx
    }

    /// Tears down a device's context once no remaining tab targets it.
    private func releaseContextIfUnused(_ deviceID: String) {
        let stillUsed = sessions.contains { ($0 as? LogSession)?.device.id == deviceID
            || ($0 as? NetworkSession)?.device.id == deviceID }
        if !stillUsed, let ctx = deviceContexts.removeValue(forKey: deviceID) { ctx.stop() }
    }

    // MARK: - Sessions

    @discardableResult
    func startSession(for device: Device, filter: LogFilter = LogFilter(),
                      name: String? = nil, autoStart: Bool = true) -> LogSession? {
        mode = .devices   // opening a device session returns to the devices/sessions view
        guard makeLogSource(for: device) != nil else { return nil }   // device has a usable source
        var filter = filter
        filter.exclusions = LogExclusionStore.shared.rules            // global hidden-message rules
        let store = history
        // adbURL is only used by the Android pid/clear helpers; a placeholder is
        // fine for iOS sessions (they never call those paths).
        let toolURL = adbURL ?? AppleToolchain.xcrun
        // A factory (not a fixed instance) so the session can re-spawn the tool to
        // auto-reconnect after a device/stream drop.
        let adb = adbURL
        let makeSource: @Sendable (String) -> LogSource? = { bundleID in
            switch device.platform {
            case .android: return adb.map { AndroidLogSource(adbURL: $0, serial: device.id) }
            case .iosSimulator: return SimulatorLogSource(udid: device.id)
            case .iosDevice:
                // Whole device → passive structured stream via Apple's LoggingSupport
                // engine (real level · subsystem · category, no app launch); falls back to
                // idevicesyslog internally if the private API is unavailable. Its catch:
                // private os_log args arrive as <private> (the relay redacts them).
                //
                // A targeted app → launch it under devicectl's console with
                // OS_ACTIVITY_DT_MODE=enable, which mirrors that app's os_log **un-redacted**
                // plus print()/stdout — the Xcode-console experience, scoped to the app.
                // `bundleID` is the app's bundle id (launching is by bundle id, so it
                // re-launches the app each time capture starts, by design).
                return bundleID.isEmpty
                    ? IOSDeviceOSLogSource(udid: device.id, processFilter: nil)
                    : IOSDeviceConsoleLogSource(udid: device.id, bundleID: bundleID)
            }
        }
        // Simulators can additionally stream the targeted app's stdout (`print()`),
        // which OSLog can't see, by launching it under a PTY. Other platforms have
        // no stdout tap, so they get no console source.
        let simulatorConsole: @Sendable (String) -> LogSource? = { bundleID -> LogSource? in
            guard !bundleID.isEmpty else { return nil }
            return SimulatorConsoleLogSource(udid: device.id, bundleID: bundleID)
        }
        let makeConsoleSource: (@Sendable (String) -> LogSource?)? =
            device.platform == .iosSimulator ? simulatorConsole : nil
        let session = LogSession(
            device: device, makeSource: makeSource, adbURL: toolURL,
            filter: filter, displayName: name,
            makeConsoleSource: makeConsoleSource,
            onPersist: { sid, lines in
                Task { await store?.appendLines(sessionID: sid, lines) }
            }
        )
        let id = session.id
        session.deviceContext = context(for: device)
        session.onStateChanged = { [weak self] in self?.persistTabs() }
        // Record history on each (re)start, whether auto-started or started later.
        session.onStarted = { [weak session] in
            guard let session else { return }
            let pkg = session.filter.packageLabel
            let displayName = session.displayName
            Task {
                await store?.upsertDevice(device)
                await store?.beginSession(id: id, device: device, package: pkg, displayName: displayName)
            }
        }
        sessions.append(session)
        selectedSessionID = session.id
        if autoStart { session.start() }
        persistTabs()
        return session
    }

    private var ca: CertificateAuthority?
    /// Shared on-disk cache for older network-transaction bodies (keeps RAM flat on
    /// long-running capture sessions).
    private let bodyCache = NetworkBodyCache()

    /// The shared CA, minted (and persisted, key in the Keychain) on first use. Also feeds
    /// the onboarding web server so a phone can download and trust the cert.
    private func ensureCA() -> CertificateAuthority? {
        if let ca { return ca }
        guard let made = try? CertificateAuthority() else { return nil }
        ca = made
        return made
    }

    /// Opens a Database tab for the device (browse an app's local SQLite DB).
    @discardableResult
    func startDatabaseSession(for device: Device) -> DatabaseSession {
        mode = .devices
        let session = DatabaseSession(device: device, adbURL: adbURL)
        sessions.append(session)
        selectedSessionID = session.id
        return session
    }

    /// Opens a Cloud Logging session for a GCP project (req 6). Like device sessions it lives in
    /// the shared tab strip; it starts streaming only when the user presses Start (req: the
    /// start/stop control drives streaming/polling), so opening a tab is cheap.
    @discardableResult
    func startCloudLogSession(projectID: String, autoStart: Bool = false,
                              displayName: String? = nil,
                              query: CloudLogQuery = CloudLogQuery(),
                              timeRange: CloudTimeRange = .last(minutes: 15),
                              rawFilter: String? = nil) -> CloudLogSession {
        mode = .devices   // opening a session returns to the shared session view
        let session = CloudLogSession(projectID: projectID, registry: cloudLogging,
                                      displayName: displayName, query: query, timeRange: timeRange,
                                      rawFilter: rawFilter)
        session.onStateChanged = { [weak self] in self?.persistTabs() }
        sessions.append(session)
        selectedSessionID = session.id
        if autoStart { session.start() }
        persistTabs()
        return session
    }

    @discardableResult
    func startNetworkSession(for device: Device, name: String? = nil, autoStart: Bool = true) -> NetworkSession? {
        mode = .devices   // opening a session returns to the devices/sessions view
        guard let authority = ensureCA() else { return nil }
        let session = NetworkSession(device: device, ca: authority, adbURL: adbURL,
                                     displayName: name, bodyCache: bodyCache, companions: companions)
        session.deviceContext = context(for: device)
        session.onStateChanged = { [weak self] in self?.persistTabs() }
        // Companion-only devices have no proxy/agent path — pre-select companion so the
        // tab is ready to stream (the network inspection "just knows").
        if device.isCompanion { session.restoreMode(.companion, package: nil) }
        sessions.append(session)
        selectedSessionID = session.id
        if autoStart { session.start() }
        persistTabs()
        return session
    }

    /// The result of a one-click companion update over USB.
    enum CompanionUpdateOutcome: Equatable { case noUSBPath, success, failed(String) }

    /// One-click companion update for an adb-connected device: push the bundled APK over USB and
    /// relaunch, no QR step. Over adb the link re-establishes itself and the "update" flag clears
    /// once the new build reports its commit. Returns `.noUSBPath` when there's no adb path (the
    /// caller then falls back to the QR/connect sheet — e.g. a companion-only, Wi-Fi device).
    func updateCompanionOverUSB(_ device: Device) async -> CompanionUpdateOutcome {
        guard device.platform == .android, !device.isCompanion, adbURL != nil else { return .noUSBPath }
        if let error = await companionSetup.installApk(on: device.id) { return .failed(error) }
        return .success
    }

    // MARK: - Stranded device proxy (cleanup backstop)

    /// The device's current global HTTP proxy if it points at this Mac — a proxy left
    /// behind by an older proxy-mode Jaca. Drives the sidebar "Revert" one-click fix.
    /// (Companion capture never sets a device proxy, so this only cleans up legacy state.)
    func strandedProxy(for device: Device) async -> String? {
        guard device.platform == .android, let adbURL else { return nil }
        guard let current = await ProxyConfigurator.currentAndroidProxy(adbURL: adbURL, serial: device.id) else {
            return nil
        }
        let ours = ProxyConfigurator.hostAddress(for: device)
        return ProxyConfigurator.proxyHost(current) == ours ? current : nil
    }

    /// Clears the device's global HTTP proxy — the sidebar "Revert" action.
    func revertDeviceProxy(_ device: Device) async {
        guard device.platform == .android, let adbURL else { return }
        await ProxyConfigurator.clearAndroidProxy(adbURL: adbURL, serial: device.id)
    }

    private func makeLogSource(for device: Device) -> LogSource? {
        switch device.platform {
        case .android:
            guard let adbURL else { return nil }
            return AndroidLogSource(adbURL: adbURL, serial: device.id)
        case .iosSimulator:
            return SimulatorLogSource(udid: device.id)
        case .iosDevice:
            return IOSDeviceLogSource(udid: device.id)
        }
    }

    func closeSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].stop()
        if sessions[index] is LogSession {
            let store = history
            Task { await store?.endSession(id: id) }
        }
        // Cloud Logging tabs own a per-session SQLite file; delete it on close.
        if let cloud = sessions[index] as? CloudLogSession { cloud.dispose() }
        let deviceID = (sessions[index] as? LogSession)?.device.id
            ?? (sessions[index] as? NetworkSession)?.device.id
        sessions.remove(at: index)
        if let deviceID { releaseContextIfUnused(deviceID) }
        if selectedSessionID == id {
            selectedSessionID = sessions[safe: index]?.id ?? sessions.last?.id
        }
        persistTabs()
    }

    func select(_ id: UUID) { selectedSessionID = id }

    /// Reorders tabs: move the dragged session to the target's position.
    func moveSession(dragging id: UUID, over targetID: UUID) {
        guard id != targetID,
              let from = sessions.firstIndex(where: { $0.id == id }),
              let to = sessions.firstIndex(where: { $0.id == targetID }) else { return }
        let item = sessions.remove(at: from)
        sessions.insert(item, at: to)
        persistTabs()
    }

    /// Cycles the selected tab (Shift+Tab), wrapping around.
    func cycleTab(forward: Bool) {
        guard !sessions.isEmpty else { return }
        let ids = sessions.map(\.id)
        let current = selectedSessionID.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = forward ? (current + 1) % ids.count : (current - 1 + ids.count) % ids.count
        selectedSessionID = ids[next]
    }
}

/// Lightweight, Codable snapshot of a tab for session restore.
struct TabDescriptor: Codable {
    enum Kind: String, Codable { case log, network, cloud }
    var kind: Kind
    var platform: DevicePlatform
    var deviceID: String
    var displayName: String
    var minLevel: Int
    var query: String
    var isRegex: Bool
    var packageLabel: String
    /// Network tabs only: "proxy" or "agent". Optional so tabs persisted before
    /// this field still decode (defaults to proxy on restore).
    var captureMode: String?
    /// Cloud Logging tabs only — the project + its persisted server-side query/time window
    /// (and a raw filter when ingested from a URL). Optional so older persisted tabs still decode.
    var projectID: String?
    var cloudQuery: CloudLogQuery?
    var cloudTimeRange: CloudTimeRange?
    var cloudRawFilter: String?

    func matches(_ other: TabDescriptor) -> Bool {
        kind == other.kind && deviceID == other.deviceID && displayName == other.displayName
    }

    enum CodingKeys: String, CodingKey {
        case kind, platform, deviceID, displayName, minLevel, query, isRegex, packageLabel,
             captureMode, projectID, cloudQuery, cloudTimeRange, cloudRawFilter
    }
}

extension TabDescriptor {
    /// Migration-safe decode: only `kind` is required (a tab with no kind is meaningless and is
    /// skipped by the element-wise loader); everything else falls back to a default, so adding a
    /// field never invalidates a saved tab.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        platform = try c.decodeIfPresent(DevicePlatform.self, forKey: .platform) ?? .android
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        minLevel = try c.decodeIfPresent(Int.self, forKey: .minLevel) ?? 0
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? ""
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        packageLabel = try c.decodeIfPresent(String.self, forKey: .packageLabel) ?? ""
        captureMode = try c.decodeIfPresent(String.self, forKey: .captureMode)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        cloudQuery = try c.decodeIfPresent(CloudLogQuery.self, forKey: .cloudQuery)
        cloudTimeRange = try c.decodeIfPresent(CloudTimeRange.self, forKey: .cloudTimeRange)
        cloudRawFilter = try c.decodeIfPresent(String.self, forKey: .cloudRawFilter)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
