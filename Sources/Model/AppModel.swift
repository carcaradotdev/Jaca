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

    /// Agent HTTPS debugging (the default, with response overrides) or MITM HTTPS debugging — one
    /// or the other; see `FeatureFlags.networkInspectionMode`. Persisted across launches.
    ///
    /// With the `network` daemon area on, `jacad` owns the mode: this reads its mirror
    /// (`RemoteNetworkMode`) and the setter asks the daemon to switch. With the area off, the app
    /// owns it, and the setter runs the switch here (`switchModeInProcess`). Neither path starts
    /// a capture; tabs whose source the new mode doesn't offer stop and show the chooser.
    var networkInspectionMode: NetworkInspectionMode {
        get { remoteMode?.mode ?? appliedMode }
        set { requestMode(newValue) }
    }

    /// True while a mode switch stops captures and waits for their devices. Settings disables
    /// the choice meanwhile.
    var isSwitchingNetworkMode: Bool { (remoteMode?.switching ?? false) || isSwitchingLocally }

    /// The mode this process's own side runs: its in-process tabs, and the companion subsystem.
    /// It follows the daemon's mode when the daemon owns it.
    private(set) var appliedMode: NetworkInspectionMode = FeatureFlags.networkInspectionMode
    private(set) var isSwitchingLocally = false
    /// Why the last mode switch that the daemon ran failed. Settings shows it under the
    /// options. nil after a switch that worked, and when a new switch starts.
    private(set) var networkModeError: String?
    /// The mirror of `jacad`'s mode. nil when the `network` daemon area is off.
    private let remoteMode: RemoteNetworkMode?
    /// Switches run one at a time, in the order asked.
    @ObservationIgnored private var modeSwitchChain: Task<Void, Never>?
    @ObservationIgnored private var modeObserver: NSObjectProtocol?

    /// MITM HTTPS debugging, which includes companion capture. When off, the companion subsystem
    /// is never started.
    var httpsDecryptionEnabled: Bool { appliedMode == .mitmHTTPSDebugging }

    /// Agent HTTPS debugging.
    var responseOverridesEnabled: Bool { appliedMode == .agentHTTPSDebugging }

    /// The unified Projects area state: auto-detected Claude projects + user-added
    /// folders, their worktrees, and per-checkout cache cleanup.
    let projects = ProjectsModel()

    /// The single source of truth for response-override rules, read by every `NetworkSession` and
    /// all the override UI, so two tabs can never disagree about what is mocked.
    let overrides = OverridesModel()

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

    /// Discovered adb/simulator/iOS devices, platform-ordered, before companions are merged
    /// in. Fed by the in-process `DevicesEngine`, or by `jacad`'s `devices.list` in daemon mode.
    private var discovered: [Device] = []
    private var deviceEngine: DevicesEngine?
    private var deviceWatch: Task<Void, Never>?
    private var discoveryStarted = false
    private let daemon = DaemonConnector.shared

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
        remoteMode = (!uiTestMode && DaemonConnector.shared.isEnabled(.network))
            ? RemoteNetworkMode(daemon: DaemonConnector.shared) : nil
        resolveADB()
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
        startModeOwnership()
    }

    /// adb for this process's own sessions (log streams, CA install). Discovery resolves its
    /// own through `DevicesEngine` from the same setting.
    private func resolveADB() {
        adbURL = AndroidToolchain.adbURL(override: UserDefaults.standard.string(forKey: DevicesEngine.adbPathKey))
    }

    /// Re-resolves the toolchain (e.g. after the adb path changes in Settings)
    /// and restarts discovery.
    func reloadProviders() {
        resolveADB()
        discovered = []
        recomputeDevices()
        guard daemon.isEnabled(.devices), deviceEngine == nil else {
            deviceEngine?.reload()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                if try await self.daemon.request("devices.reload", RPCEmpty(), as: RPCEmpty.self) != nil { return }
            } catch {
                return   // reached the daemon and failed; its discovery keeps running
            }
            self.startLocalDiscovery()   // daemon unreachable: discover in-process
        }
    }

    // MARK: - Discovery

    func startDiscovery() {
        guard !discoveryStarted else { return }
        discoveryStarted = true
        if daemon.isEnabled(.devices) {
            // The daemon's shared discovery; while it's unreachable, discover in-process.
            deviceWatch = daemon.watch([DevicesArea.listTopic],
                                       onUnavailable: { [weak self] in self?.startLocalDiscovery() }) { [weak self] event in
                guard let self, let list = try? event.decode([Device].self) else { return }
                if let local = self.deviceEngine {
                    local.stop()
                    local.onChange = nil
                    self.deviceEngine = nil
                }
                self.applyDiscovered(list)
            }
        } else {
            startLocalDiscovery()
        }
        // Companion discovery is owned by `companions` (the single source of truth). It folds
        // its devices into the list via the `onChange` wired in init. Started only when the
        // experimental HTTPS-decryption feature is on — otherwise the companion subsystem never
        // initializes and network inspection stays Agent-only.
        if !uiTestMode && httpsDecryptionEnabled { companions.start() }
    }

    @discardableResult
    private func startLocalDiscovery() -> DevicesEngine? {
        if let deviceEngine { return deviceEngine }
        let engine = DevicesEngine(defaults: .standard)
        engine.onChange = { [weak self] in self?.applyDiscovered($0) }
        engine.start()
        deviceEngine = engine
        return engine
    }

    private func applyDiscovered(_ list: [Device]) {
        discovered = list
        // Feed adb-connected Android devices to the registry (only when the experimental
        // feature is on) so it can discover their companion IP.
        if !uiTestMode, httpsDecryptionEnabled {
            companions.setADBCompanionDevices(
                list.filter { $0.platform == .android && $0.state.isReady }.map { (serial: $0.id, model: $0.model) })
        }
        recomputeDevices()
    }

    // MARK: - Network inspection mode

    /// Mirrors the daemon's mode, or follows a mode another process stored while the app owns it.
    private func startModeOwnership() {
        guard !uiTestMode else { return }
        if let remoteMode {
            remoteMode.onModeChange = { [weak self] mode in self?.followMode(mode) }
            remoteMode.start()
            return
        }
        // The app owns the mode, but `jaca net mode` or Herdr can store another one through a
        // `jacad` that runs without the app's network area. Follow it, reactively.
        let ownPid = String(ProcessInfo.processInfo.processIdentifier)
        modeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NetworkModeStore.changedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard (note.object as? String) != ownPid else { return }
            MainActor.assumeIsolated { self?.followMode(FeatureFlags.networkInspectionMode) }
        }
    }

    /// The setter of `networkInspectionMode`.
    private func requestMode(_ target: NetworkInspectionMode) {
        guard target != networkInspectionMode else { return }
        networkModeError = nil
        guard let remoteMode else {
            enqueueModeSwitch(to: target, persist: true)
            return
        }
        Task { [weak self] in
            switch await remoteMode.set(target) {
            case .reachedDaemon:
                break
            case .unreachable:
                // No daemon answered: nothing else runs the switch, so do it here. The daemon
                // reads the stored mode when it starts. The mirror forgot the daemon's old mode,
                // so the setting now reads `appliedMode`.
                self?.enqueueModeSwitch(to: target, persist: true)
            case .failed(let message):
                self?.networkModeError = message
            }
        }
    }

    /// Applies a mode that another owner already stored: the daemon's mirror, or a notification.
    private func followMode(_ mode: NetworkInspectionMode) {
        enqueueModeSwitch(to: mode, persist: false)
    }

    private func enqueueModeSwitch(to target: NetworkInspectionMode, persist: Bool) {
        let previous = modeSwitchChain
        modeSwitchChain = Task { [weak self] in
            await previous?.value
            await self?.switchModeInProcess(to: target, persist: persist)
        }
    }

    /// The app's copy of `NetworkModeController`'s switch, over the tabs that capture in this
    /// process. With the daemon owning the mode, those are only companion-only tabs; `jacad`
    /// switches its own captures.
    /// 1. Stop each in-process tab whose source the new mode doesn't offer, and show its chooser.
    /// 2. Wait until every device teardown is done.
    /// 3. Persist the mode and announce it (only when this process owns it).
    /// 4. Refresh what each in-process tab offers, and start or stop the companion subsystem.
    private func switchModeInProcess(to target: NetworkInspectionMode, persist: Bool) async {
        guard target != appliedMode else { return }
        JacaLog.info("network", "inspection mode: \(appliedMode.wireName) -> \(target.wireName)")
        isSwitchingLocally = true
        defer { isSwitchingLocally = false }
        let strategy = HTTPDebuggingStrategies.strategy(for: target)
        let local = sessions.compactMap { $0 as? NetworkSession }.filter { !$0.isRemote }
        let plan = ModeSwitchPlan.make(
            captures: local.map { ModeSwitchPlan.Capture(id: $0.id, device: $0.device,
                                                         sourceID: $0.hasSelectedMode ? $0.selectedSourceID : nil) },
            to: strategy)
        for session in local where plan[session.id] == .stopAndReopenChooser {
            session.reopenModeChooser()
        }
        await NetworkModeController.settleDevices()
        if persist {
            NetworkModeStore.live.write(target)
            NetworkModeStore.live.announce()
        }
        let wasMITM = httpsDecryptionEnabled
        appliedMode = target
        // Read again: a tab opened while the devices settled must offer the new mode's sources too.
        for case let session as NetworkSession in sessions where !session.isRemote {
            session.localEngine?.refreshOffered(strategy: strategy)
        }
        if wasMITM != httpsDecryptionEnabled { reconfigureCompanion() }
        persistTabs()
    }

    /// Start or tear down the companion subsystem when the feature flag toggles at runtime.
    private func reconfigureCompanion() {
        if httpsDecryptionEnabled {
            companions.start()
            companions.setADBCompanionDevices(
                discovered.filter { $0.platform == .android && $0.state.isReady }.map { (serial: $0.id, model: $0.model) })
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
        var merged = discovered

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
                        rawFilter: descriptor.cloudRawFilter, sessionID: descriptor.sessionID)
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
                filter.packageLabel = descriptor.packageLabel
                // Same id as before, so a daemon session still running is reattached.
                startSession(for: device, filter: filter, name: descriptor.displayName, autoStart: false,
                             sessionID: descriptor.sessionID)
            case .network:
                let session = startNetworkSession(for: device, name: descriptor.displayName, autoStart: false,
                                                  sessionID: descriptor.sessionID)
                // Pre-configure the chosen mode so the tab restores ready-to-run:
                // the user just presses play (no re-picking from the chooser).
                // An id this build doesn't know, or none, opens the chooser.
                let pkg = descriptor.packageLabel.isEmpty ? nil : descriptor.packageLabel
                if let kind = descriptor.captureMode.flatMap({ CaptureSourceRegistry.descriptor(id: $0)?.kind }) {
                    session?.restoreMode(kind, package: pkg)
                }
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
                                 packageLabel: log.filter.packageLabel, sessionID: log.id)
        }
        if let net = tab as? NetworkSession {
            return TabDescriptor(kind: .network, platform: net.device.platform, deviceID: net.device.id,
                                 displayName: net.displayName, minLevel: 0, query: "",
                                 isRegex: false, packageLabel: net.targetPackage ?? "",
                                 captureMode: net.hasSelectedMode ? net.currentDescriptor?.id : nil,
                                 sessionID: net.id)
        }
        if let cloud = tab as? CloudLogSession {
            return TabDescriptor(kind: .cloud, platform: .android, deviceID: "",
                                 displayName: cloud.displayName, minLevel: 0, query: "",
                                 isRegex: false, packageLabel: "",
                                 projectID: cloud.projectID, cloudQuery: cloud.query,
                                 cloudTimeRange: cloud.timeRange, cloudRawFilter: cloud.rawFilter,
                                 sessionID: cloud.id)
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
                      name: String? = nil, autoStart: Bool = true, sessionID: UUID? = nil) -> LogSession? {
        mode = .devices   // opening a device session returns to the devices/sessions view
        guard LogSources.isSupported(device, adbURL: adbURL) else { return nil }   // device has a usable source
        var filter = filter
        filter.exclusions = LogExclusionStore.shared.rules            // global hidden-message rules
        // A restored id only matters in daemon mode, where it reattaches to a still-running
        // session. In-process each run is new, and reusing the id would merge history runs.
        let id = (daemon.isEnabled(.logs) ? sessionID : nil) ?? UUID()
        // adbURL is only used by the Android pid/clear helpers; a placeholder is
        // fine for iOS sessions (they never call those paths).
        let toolURL = adbURL ?? AppleToolchain.xcrun
        let session: LogSession
        if daemon.isEnabled(.logs) {
            // The stream runs in jacad (which records history); this tab attaches to it by id,
            // so a relaunch reattaches to a session that is still running. If jacad can't be
            // reached the tab streams in-process instead, recording history here.
            let store = history, adb = adbURL
            let feed = RemoteLogFeed(id: id, device: device, package: filter.packageLabel,
                                     displayName: name ?? device.displayModel, autoStart: autoStart,
                                     daemon: daemon, makeLocal: { seqStart, currentName in
                let historyID = UUID()
                let engine = LogStreamEngine(
                    device: device, adbURL: adb, seqStart: seqStart,
                    onPersist: { _, lines in Task { await store?.appendLines(sessionID: historyID, lines) } },
                    prettifyEnabled: { LogBodyPrettifyStore.shared.enabled })
                engine.onStarted = { [weak engine] in
                    let pkg = engine?.state.package ?? ""
                    let name = currentName()   // the tab's name now: it may have been renamed
                    Task {
                        await store?.upsertDevice(device)
                        await store?.beginSession(id: historyID, device: device, package: pkg,
                                                  displayName: name)
                    }
                }
                engine.onClosed = { Task { await store?.endSession(id: historyID) } }
                return engine
            })
            session = LogSession(id: id, device: device, feed: feed, adbURL: toolURL, filter: filter,
                                 displayName: name, isRemote: true)
        } else {
            let store = history
            session = LogSession(
                id: id, device: device,
                makeSource: LogSources.primary(for: device, adbURL: adbURL),
                adbURL: toolURL, filter: filter, displayName: name,
                makeConsoleSource: LogSources.console(for: device),
                onPersist: { sid, lines in
                    Task { await store?.appendLines(sessionID: sid, lines) }
                }
            )
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
            if autoStart { session.start() }
        }
        session.deviceContext = context(for: device)
        session.onStateChanged = { [weak self] in self?.persistTabs() }
        sessions.append(session)
        selectedSessionID = session.id
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
                              rawFilter: String? = nil,
                              sessionID: UUID? = nil) -> CloudLogSession {
        mode = .devices   // opening a session returns to the shared session view
        // Same id as before on restore, so a daemon-mode tab reattaches to its stream.
        // The persisted id reattaches to the daemon's session. In-process a relaunch starts
        // fresh: the id names the per-session database, which would mix in the last run's rows.
        let id = (daemon.isEnabled(.cloudLogging) ? sessionID : nil) ?? UUID()
        let session = CloudLogSession(id: id, projectID: projectID, registry: cloudLogging,
                                      displayName: displayName, query: query, timeRange: timeRange,
                                      rawFilter: rawFilter, autoStart: autoStart)
        session.onStateChanged = { [weak self] in self?.persistTabs() }
        sessions.append(session)
        selectedSessionID = session.id
        if autoStart { session.start() }
        persistTabs()
        return session
    }

    @discardableResult
    func startNetworkSession(for device: Device, name: String? = nil, autoStart: Bool = true,
                             sessionID: UUID? = nil) -> NetworkSession? {
        mode = .devices   // opening a session returns to the devices/sessions view
        guard let session = makeNetworkSession(for: device, name: name, sessionID: sessionID) else { return nil }
        sessions.append(session)
        selectedSessionID = session.id
        if autoStart { session.start() }
        persistTabs()
        return session
    }

    /// Builds a network tab on the side network capture runs on (not yet in the tab strip).
    private func makeNetworkSession(for device: Device, name: String?, sessionID: UUID? = nil) -> NetworkSession? {
        guard let authority = ensureCA() else { return nil }
        let id = sessionID ?? UUID()
        let session: NetworkSession
        // Capture runs in jacad when the network daemon area is on, in either mode. A companion-only
        // device always captures in-process: the companion links live in the app.
        if daemon.networkRunsInDaemon(), !device.isCompanion {
            let feed = RemoteNetworkFeed(id: id, device: device, autoStart: false, daemon: daemon)
            session = NetworkSession(id: id, device: device, feed: feed, ca: authority, adbURL: adbURL,
                                     displayName: name, companions: companions, overrides: overrides,
                                     isRemote: true)
        } else {
            session = NetworkSession(id: id, device: device, ca: authority, adbURL: adbURL,
                                     displayName: name, bodyCache: bodyCache, companions: companions,
                                     overrides: overrides)
        }
        session.deviceContext = context(for: device)
        session.onStateChanged = { [weak self] in self?.persistTabs() }
        session.localEngine?.startGate = { [weak self] id, sourceID, package in
            self?.admitLocalStart(id, device: device, sourceID: sourceID, package: package) ?? true
        }
        // Companion-only devices have no proxy/agent path — pre-select companion so the
        // tab is ready to stream (the network inspection "just knows").
        if device.isCompanion { session.restoreMode(.companion, package: nil) }
        // This Mac has one way to capture: the Chrome window.
        if device.platform == .mac { session.restoreMode(.browser, package: nil) }
        return session
    }

    /// The start gate of each in-process capture: the app's copy of what `NetworkArea.select`
    /// does in jacad.
    /// - During a mode switch it refuses, so a tab can't start a source of the old mode while
    ///   the switch waits for its devices. The tab stays as it is.
    /// - Otherwise it stops each other in-process capture whose claim on the device collides
    ///   with the new one (two device proxies on one phone, for example), including one that is
    ///   still in its precheck. The newest capture wins.
    private func admitLocalStart(_ id: UUID, device: Device, sourceID: String, package: String?) -> Bool {
        guard !isSwitchingLocally else {
            JacaLog.info("network", "refused a start of \(sourceID) on \(device.id) during a mode switch")
            return false
        }
        let local = sessions.compactMap { $0 as? NetworkSession }.filter { !$0.isRemote && $0.id != id }
        let running: [NetworkArea.RunningCapture] = local.compactMap { session in
            guard let state = session.localEngine?.state, state.isRunning || state.isConnecting,
                  let source = state.selectedSourceID else { return nil }
            return NetworkArea.RunningCapture(id: session.id, device: session.device, sourceID: source,
                                              package: state.targetPackage)
        }
        let stop = NetworkArea.capturesToStop(running: running, starting: id, on: device, sourceID: sourceID,
                                              package: package,
                                              strategy: HTTPDebuggingStrategies.strategy(for: appliedMode))
        for session in local where stop.contains(session.id) {
            JacaLog.info("network", "stopping capture \(session.id): \(id) starts \(sourceID) on \(device.id)")
            session.stop()
        }
        return true
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

    /// The device's current global HTTP proxy if Jaca left it behind: a LAN-IP proxy from an
    /// older Jaca, or a `mitm` device proxy whose ledger entry no running capture holds. Drives
    /// the sidebar "Revert" one-click fix. A proxy that a running capture holds is not stranded.
    func strandedProxy(for device: Device) async -> String? {
        guard device.platform == .android, !device.isCompanion, let adbURL else { return nil }
        guard let current = await ProxyConfigurator.currentAndroidProxy(adbURL: adbURL, serial: device.id) else {
            return nil
        }
        let split = ledgerSplit(serial: device.id)
        if split.live.contains(current) { return nil }
        let ours = StrandedProxyMatch.isOurs(current: current, hostAddress: ProxyConfigurator.hostAddress(for: device),
                                             ledgerValues: split.stranded)
        return ours ? current : nil
    }

    /// Reverts the device's global HTTP proxy — the sidebar "Revert" action. A value from the
    /// ledger gets back what the device had before Jaca; anything else is cleared.
    func revertDeviceProxy(_ device: Device) async {
        guard device.platform == .android, let adbURL else { return }
        let serial = device.id
        let current = await ProxyConfigurator.currentAndroidProxy(adbURL: adbURL, serial: serial)
        let entries = DeviceProxyLedger.entries(serial: serial)
        if let current, let entry = entries.first(where: { $0.value == current }),
           ledgerSplit(serial: serial).stranded.contains(current) {
            let others = Set(entries.filter { $0.port != entry.port }.map(\.value))
            let reverted = await DeviceProxyOps.revert(adbURL: adbURL, serial: serial, value: entry.value,
                                                       previous: entry.previous, otherValues: others,
                                                       environment: .live)
            if reverted { DeviceProxyLedger.remove(serial: serial, port: entry.port) }
            return
        }
        await ProxyConfigurator.clearAndroidProxy(adbURL: adbURL, serial: serial)
    }

    /// This device's ledger values, split by whether a running capture holds them.
    private func ledgerSplit(serial: String) -> StrandedProxyMatch.LedgerSplit {
        StrandedProxyMatch.split(
            entries: DeviceProxyLedger.entries(serial: serial),
            ownPid: ProcessInfo.processInfo.processIdentifier,
            armedPorts: DeviceProxyCaptureSource.armedPorts[serial] ?? [],
            pidAlive: DeviceProxyLedger.liveOwnerCheck, now: Date())
    }

    func closeSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].stop()
        if let log = sessions[index] as? LogSession {
            log.close()
            // A daemon session records its own end in history when it closes.
            if !log.isRemote {
                let store = history
                Task { await store?.endSession(id: id) }
            }
        }
        // Cloud Logging tabs own a per-session SQLite file; delete it on close.
        if let cloud = sessions[index] as? CloudLogSession { cloud.dispose() }
        if let net = sessions[index] as? NetworkSession { net.close() }
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
    /// The tab's session id, so a daemon-mode tab reattaches to its still-running stream.
    var sessionID: UUID?

    func matches(_ other: TabDescriptor) -> Bool {
        kind == other.kind && deviceID == other.deviceID && displayName == other.displayName
    }

    enum CodingKeys: String, CodingKey {
        case kind, platform, deviceID, displayName, minLevel, query, isRegex, packageLabel,
             captureMode, projectID, cloudQuery, cloudTimeRange, cloudRawFilter, sessionID
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
        sessionID = try? c.decodeIfPresent(UUID.self, forKey: .sessionID)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
