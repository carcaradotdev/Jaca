import Foundation

/// Network captures in the daemon (the in-process agent, the device proxy, the iOS Simulator
/// through the Mac system proxy, and this Mac's Chrome window; companion capture stays in the
/// app). Each capture keeps its transactions, with bodies beyond the newest `bodiesInMemory`
/// spilled to `NetworkBodyCache`. Clients get upserts **without bodies** on `net.txns.<id>` and
/// fetch a transaction's bodies with `network.body` when they show it.
enum NetworkArea {
    struct OpenParams: Codable, Sendable {
        var id: UUID
        var device: Device
        /// Restore a chosen source (without starting unless `autoStart`).
        var sourceID: String?
        var package: String?
        var autoStart: Bool?
    }
    struct SelectParams: Codable, Sendable { var id: UUID; var sourceID: String; var package: String? }
    struct IDParams: Codable, Sendable { var id: UUID }
    struct SetModeParams: Codable, Sendable {
        /// A wire name: "agent" or "mitm".
        var mode: String
    }
    /// What `network.installCA` did.
    struct InstallCAResult: Codable, Sendable, Equatable {
        enum Outcome: String, Codable, Sendable { case installed, needsUser, failed }
        var outcome: Outcome
        /// Why the install failed. nil unless `outcome` is `failed`.
        var message: String?
        /// iOS Simulator: apps see the new certificate only after a reboot
        /// (`network.rebootSimulator`). nil on other devices.
        var rebootAdvised: Bool?
    }
    struct BodyParams: Codable, Sendable { var id: UUID; var transaction: UUID }
    struct Bodies: Codable, Sendable, Equatable { var request: Data?; var response: Data? }
    struct SessionInfo: Codable, Sendable, Equatable {
        var id: UUID
        var state: NetworkCaptureState
        var existed: Bool
    }
    /// One open capture, as `network.list` reports it.
    struct Session: Codable, Sendable, Equatable {
        var id: UUID
        /// The device's model, or its id when the model is unknown.
        var name: String
        var device: Device
        var state: NetworkCaptureState
        var transactionCount: Int
    }
    struct SearchParams: Codable, Sendable {
        /// One capture; nil searches every open capture.
        var id: UUID?
        var host: String?
        var method: String?
        var status: [NetworkStatusRange]?
        var failed: Bool?
        var idPrefix: String?
        /// The newest matches kept: 1...`maxSearchRows`, `defaultSearchRows` when absent.
        var limit: Int?
    }
    /// A transaction without headers or bodies, as `network.search` returns it.
    struct Row: Codable, Sendable, Equatable {
        var id: UUID
        /// The capture it belongs to.
        var session: UUID
        var method: String
        var url: String
        var host: String
        var statusCode: Int?
        var error: String?
        var startedAt: Date
        var durationMs: Int?
        var requestBytes: Int
        var responseBytes: Int
        var overriddenByRuleID: UUID?

        init(_ txn: NetworkTransaction, session: UUID) {
            id = txn.id
            self.session = session
            method = txn.method
            url = txn.url
            host = txn.host
            statusCode = txn.statusCode
            error = txn.error
            startedAt = txn.startedAt
            durationMs = txn.duration.map { Int(($0 * 1000).rounded()) }
            requestBytes = txn.requestBytes
            responseBytes = txn.responseBytes
            overriddenByRuleID = txn.overriddenByRuleID
        }
    }

    static let defaultSearchRows = 100
    static let maxSearchRows = 1_000

    static let companionInAppMessage = "Companion capture runs in the app, not in jacad."
    static let sourceNotOfferedMessage = "This capture source isn't available in the current network inspection mode."
    static let unknownModeMessage = "Unknown mode. Use agent or mitm."

    /// The error `network.select` gives for `sourceID` on `device`, or nil when the source may
    /// start. Companion capture needs the CA and the gRPC links, which stay in the app, so jacad
    /// refuses it even where the mode offers it.
    @MainActor
    static func selectRefusal(sourceID: String, device: Device, strategy: any HTTPDebuggingStrategy) -> String? {
        if sourceID == HTTPDebuggingSourceID.companion
            || CaptureSourceRegistry.descriptor(id: sourceID)?.kind == .companion {
            return companionInAppMessage
        }
        return strategy.sourceIDs(for: device).contains(sourceID) ? nil : sourceNotOfferedMessage
    }

    /// One running capture, as `capturesToStop` sees it.
    struct RunningCapture: Sendable {
        var id: UUID
        var device: Device
        var sourceID: String
        var package: String?
    }

    /// The running captures that capture `id` replaces when it starts `sourceID` on `device`:
    /// each one whose claim on the same device collides with the new claim
    /// (`DeviceClaimArbiter`). Pass only running captures.
    static func capturesToStop(running: [RunningCapture], starting id: UUID, on device: Device, sourceID: String,
                               package: String?, strategy: any HTTPDebuggingStrategy) -> [UUID] {
        let claim = strategy.claim(device: device, sourceID: sourceID, package: package)
        let held = running.map {
            DeviceClaimArbiter.Running(id: $0.id, deviceID: $0.device.id,
                                       claim: strategy.claim(device: $0.device, sourceID: $0.sourceID, package: $0.package))
        }
        return DeviceClaimArbiter.decide(running: held, starting: id, deviceID: device.id, claim: claim)
    }

    static let noCAMessage = "Couldn’t read Jaca’s certificate. Check ~/.jaca/jacad.log."
    static let adbMissingMessage = "adb not found. Set its path in Settings or install Android platform-tools."
    static let pushFailedMessage = "Couldn't copy the certificate to the device."
    static let installCAUnsupportedMessage = "Jaca can install its certificate only on an Android device or an iOS Simulator."   // COPY-PENDING
    static let rebootNotSimulatorMessage = "Only an iOS Simulator can be rebooted from here."   // COPY-PENDING

    /// The `network.installCA` result of an Android install. `pushed` is whether the copy to
    /// Download worked; nil when no copy was tried.
    static func installCAResult(android outcome: HeadlessCAOutcome, pushed: Bool?) -> InstallCAResult {
        switch outcome {
        case .installed:
            return InstallCAResult(outcome: .installed)
        case .failed(let message):
            return InstallCAResult(outcome: .failed, message: message)
        case .notRooted:
            return pushed == true
                ? InstallCAResult(outcome: .needsUser)
                : InstallCAResult(outcome: .failed, message: pushFailedMessage)
        }
    }

    /// The `network.installCA` result of a simulator install. A reboot is advised after it.
    static func installCAResult(simulator result: Result<Void, SimulatorCAError>) -> InstallCAResult {
        switch result {
        case .success: return InstallCAResult(outcome: .installed, rebootAdvised: true)
        case .failure(let error): return InstallCAResult(outcome: .failed, message: error.message)
        }
    }

    /// The source a restored tab keeps: nil when the mode no longer offers it, or when it is
    /// companion capture, which stays in the app. Such a tab opens at the chooser.
    @MainActor
    static func restoredSourceID(_ sourceID: String?, device: Device, strategy: any HTTPDebuggingStrategy) -> String? {
        guard let sourceID else { return nil }
        return selectRefusal(sourceID: sourceID, device: device, strategy: strategy) == nil ? sourceID : nil
    }

    /// The mode a `network.setMode` wire name names. Throws `invalidParams` for any other name.
    static func mode(wireName: String) throws -> NetworkInspectionMode {
        guard let mode = NetworkInspectionMode(wireName: wireName) else {
            throw RPCError.invalidParams(unknownModeMessage)
        }
        return mode
    }

    static func transactionsTopic(_ id: UUID) -> String { "net.txns.\(id.uuidString)" }
    static func stateTopic(_ id: UUID) -> String { "net.state.\(id.uuidString)" }

    @MainActor
    final class Captures {
        final class Hosted {
            let engine: NetworkCaptureEngine
            let device: Device
            var transactions: [NetworkTransaction] = []
            var indexByID: [UUID: Int] = [:]
            /// Upserts not yet published, coalesced by id, in first-seen order.
            var outgoing: [UUID: NetworkTransaction] = [:]
            var outgoingOrder: [UUID] = []
            var unwatchedSince: Date? = Date()
            init(engine: NetworkCaptureEngine, device: Device) {
                self.engine = engine
                self.device = device
            }
        }

        private(set) var sessions: [UUID: Hosted] = [:]
        private var contexts: [String: DeviceContext] = [:]
        let bus: DaemonEventBus
        let bodyCache: NetworkBodyCache?
        let bodiesInMemory: Int
        let orphanTimeout: TimeInterval
        private var flushTask: Task<Void, Never>?
        /// The latest spill per transaction. A later one waits for it, so two saves of one row
        /// can't reach the cache out of order and leave its older bodies there.
        private var spills: [UUID: (generation: Int, task: Task<Void, Never>)] = [:]
        private var spillGeneration = 0
        /// Override services for a new capture source (nil when overrides are off).
        var interceptServices: () -> InterceptServices? = { nil }
        /// The app's CA, read the first time a capture source or `network.installCA` needs it.
        /// jacad never migrates a key from the Keychain, so it never shows a Keychain prompt.
        var loadCA: () -> CertificateAuthority? = {
            do { return try CertificateAuthority(allowKeychainMigration: false) } catch {
                DaemonLog.error("couldn't read the CA: \(error)")
                return nil
            }
        }
        private var ca: CertificateAuthority?
        /// The owner of the network inspection mode. nil in tests that install no controller;
        /// then the persisted mode applies.
        weak var modeController: NetworkModeController?
        /// The CA installers `network.installCA` runs.
        var caInstall: NetworkCAInstall = .live
        /// adb, as Settings sets it.
        var resolveADB: () -> URL? = {
            AndroidToolchain.adbURL(override: JacaDefaults.shared.string(forKey: DevicesEngine.adbPathKey))
        }

        init(bus: DaemonEventBus, bodyCache: NetworkBodyCache? = NetworkBodyCache(name: "net-bodies-jacad"),
             bodiesInMemory: Int = 1_000, orphanTimeout: TimeInterval = 600) {
            self.bus = bus
            self.bodyCache = bodyCache
            self.bodiesInMemory = bodiesInMemory
            self.orphanTimeout = orphanTimeout
        }

        var isBusy: Bool {
            sessions.values.contains { $0.engine.state.isRunning } || (modeController?.isSwitching ?? false)
        }

        /// The strategy of the current network inspection mode.
        var strategy: any HTTPDebuggingStrategy { modeController?.strategy ?? HTTPDebuggingStrategies.current }

        /// Returns when no mode switch is queued or running.
        func idle() async { await modeController?.idle() }

        /// The CA, loaded on first use. A failed load is tried again next time, so a CA that the
        /// app writes later is found without a restart.
        func currentCA() -> CertificateAuthority? {
            if ca == nil { ca = loadCA() }
            return ca
        }

        /// `open`, after any mode switch in progress.
        func openWhenIdle(_ p: OpenParams) async -> SessionInfo {
            await idle()
            return open(p)
        }

        /// `select`, after any mode switch in progress.
        func selectWhenIdle(_ id: UUID, sourceID: String, package: String?) async throws {
            await idle()
            try select(id, sourceID: sourceID, package: package)
        }

        func open(_ p: OpenParams) -> SessionInfo {
            if let existing = sessions[p.id] {
                return SessionInfo(id: p.id, state: existing.engine.state, existed: true)
            }
            let adb = resolveADB()
            let context = context(for: p.device, adbURL: adb)
            let intercept = interceptServices
            let engine = NetworkCaptureEngine(id: p.id, device: p.device, adbURL: adb,
                                              ca: { [weak self] in self?.currentCA() }, companion: nil,
                                              deviceContext: { context }, interceptServices: { intercept() })
            let strategy = self.strategy
            engine.refreshOffered(strategy: strategy)
            let hosted = Hosted(engine: engine, device: p.device)
            sessions[p.id] = hosted
            let id = p.id, bus = self.bus
            engine.onTransactions = { [weak self, weak hosted] batch in
                guard let self, let hosted else { return }
                for txn in batch { self.store(txn, in: hosted) }
                self.scheduleFlush()
            }
            engine.onState = { bus.publish(NetworkArea.stateTopic(id), $0, retain: true) }
            // A source the mode no longer offers, or companion capture (it stays in the app, see
            // `network.select`): such a tab reopens at the chooser.
            let sourceID = NetworkArea.restoredSourceID(p.sourceID, device: p.device, strategy: strategy)
            engine.restoreMode(sourceID: sourceID, package: p.package)
            bus.publish(NetworkArea.stateTopic(id), engine.state, retain: true)
            if p.autoStart == true, let sourceID {
                stopOthers(starting: id, on: p.device, sourceID: sourceID, package: engine.state.targetPackage)
                engine.resume()
            }
            return SessionInfo(id: id, state: engine.state, existed: false)
        }

        /// Starts a capture: first stops every running capture whose claim on the same device
        /// collides with it (`DeviceClaimArbiter`). Two agent captures of one app take the
        /// agent's connection from each other, and a device proxy changes the whole device. The
        /// newest one wins; the stopped ones keep what they recorded.
        ///
        /// Throws `invalidParams` for a source the current mode does not offer on the device.
        func select(_ id: UUID, sourceID: String, package: String?) throws {
            let hosted = try session(id)
            if let refusal = NetworkArea.selectRefusal(sourceID: sourceID, device: hosted.device, strategy: strategy) {
                throw RPCError.invalidParams(refusal)
            }
            let needsPackage = CaptureSourceRegistry.descriptor(id: sourceID)?.needsPackage ?? false
            stopOthers(starting: id, on: hosted.device, sourceID: sourceID, package: needsPackage ? package : nil)
            hosted.engine.select(sourceID: sourceID, package: package)
        }

        private func stopOthers(starting id: UUID, on device: Device, sourceID: String, package: String?) {
            let running: [NetworkArea.RunningCapture] = sessions.compactMap { otherID, hosted in
                let state = hosted.engine.state
                // A capture in its precheck counts too: it arms when the precheck ends.
                guard state.isRunning || state.isConnecting, let otherSource = state.selectedSourceID else { return nil }
                return NetworkArea.RunningCapture(id: otherID, device: hosted.device, sourceID: otherSource,
                                                  package: state.targetPackage)
            }
            let stop = NetworkArea.capturesToStop(running: running, starting: id, on: device, sourceID: sourceID,
                                                  package: package, strategy: strategy)
            for other in stop {
                DaemonLog.info("stopping network capture \(other): capture \(id) starts \(sourceID) on \(device.id)")
                sessions[other]?.engine.stop()
            }
        }

        /// Every open capture, as a mode switch sees it. A capture at the chooser has no source.
        func modeSwitchCaptures() -> [ModeSwitchPlan.Capture] {
            sessions.map { id, hosted in
                let state = hosted.engine.state
                return ModeSwitchPlan.Capture(id: id, device: hosted.device,
                                              sourceID: state.hasSelectedMode ? state.selectedSourceID : nil)
            }
        }

        /// Reads the offered sources of every capture again, and publishes each state, after a
        /// mode switch.
        func refreshOffered() {
            let strategy = self.strategy
            for (id, hosted) in sessions {
                hosted.engine.refreshOffered(strategy: strategy)
                bus.publish(NetworkArea.stateTopic(id), hosted.engine.state, retain: true)
            }
        }

        /// Installs Jaca's CA on the capture's device. Only a user action calls it.
        /// - iOS Simulator: adds the CA to the simulator keychain. Apps see it after a reboot.
        /// - Android: installs into the system store when `adb root` works. Otherwise copies the
        ///   CA to Download for a manual install, and returns `needsUser`.
        func installCA(_ id: UUID) async throws -> InstallCAResult {
            let result = try await installCAOnDevice(id)
            // Hosts passed through before the install failed for want of the CA. Decrypt them again.
            if result.outcome == .installed { sessions[id]?.engine.caTrustChanged() }
            return result
        }

        private func installCAOnDevice(_ id: UUID) async throws -> InstallCAResult {
            let device = try session(id).device
            guard device.platform == .android || device.platform == .iosSimulator else {
                return InstallCAResult(outcome: .failed, message: NetworkArea.installCAUnsupportedMessage)
            }
            guard let ca = currentCA() else {
                return InstallCAResult(outcome: .failed, message: NetworkArea.noCAMessage)
            }
            let install = caInstall
            if device.platform == .iosSimulator {
                let result = await install.simulatorInstall(device.id, ca.rootCertificatePEM)
                return NetworkArea.installCAResult(simulator: result)
            }
            guard let adb = resolveADB() else {
                return InstallCAResult(outcome: .failed, message: NetworkArea.adbMissingMessage)
            }
            let pem = FileManager.default.temporaryDirectory
                .appendingPathComponent("jaca-ca-\(UUID().uuidString.prefix(8)).pem")
            defer { try? FileManager.default.removeItem(at: pem) }
            do { try ca.exportRootCertificate(to: pem) } catch {
                DaemonLog.error("couldn't write the CA for \(device.id): \(error)")
                return InstallCAResult(outcome: .failed, message: NetworkArea.noCAMessage)
            }
            let rooted = await install.androidRooted(adb, device.id, pem)
            var pushed: Bool?
            if rooted == .notRooted { pushed = await install.androidPush(adb, device.id, pem) }
            return NetworkArea.installCAResult(android: rooted, pushed: pushed)
        }

        /// Reboots the capture's iOS Simulator, so its apps load a newly installed CA.
        func rebootSimulator(_ id: UUID) async throws {
            let device = try session(id).device
            guard device.platform == .iosSimulator else {
                throw RPCError.invalidParams(NetworkArea.rebootNotSimulatorMessage)
            }
            if case .failure(let error) = await caInstall.simulatorReboot(device.id) {
                throw RPCError.failed(error.message)
            }
            // The simulator's apps load the CA at boot, so a host they failed on before can work now.
            for hosted in sessions.values where hosted.device.id == device.id { hosted.engine.caTrustChanged() }
        }

        private func context(for device: Device, adbURL: URL?) -> DeviceContext {
            if let existing = contexts[device.id] { return existing }
            let ctx = DeviceContext(device: device, adbURL: adbURL)
            contexts[device.id] = ctx
            ctx.start()
            return ctx
        }

        private func store(_ txn: NetworkTransaction, in hosted: Hosted) {
            if let i = hosted.indexByID[txn.id] {
                hosted.transactions[i] = txn
                // An update to a row already out of the in-memory window brings bodies back;
                // spill them again rather than holding them for the life of the capture.
                if i < hosted.transactions.count - bodiesInMemory { spill(at: i, in: hosted) }
            } else {
                hosted.indexByID[txn.id] = hosted.transactions.count
                hosted.transactions.append(txn)
                let evict = hosted.transactions.count - bodiesInMemory - 1
                if evict >= 0 { spill(at: evict, in: hosted) }
            }
            if hosted.outgoing.updateValue(txn, forKey: txn.id) == nil { hosted.outgoingOrder.append(txn.id) }
        }

        /// Moves an older transaction's bodies to the disk cache (same window as the app's list).
        private func spill(at index: Int, in hosted: Hosted) {
            let txn = hosted.transactions[index]
            guard !txn.bodiesEvicted, txn.requestBody != nil || txn.responseBody != nil, let cache = bodyCache else { return }
            let id = txn.id, req = txn.requestBody, resp = txn.responseBody
            let previous = spills[id]?.task
            spillGeneration &+= 1
            let generation = spillGeneration
            let task = Task { @MainActor [weak self, weak hosted] in
                await previous?.value
                await cache.save(id, req: req, resp: resp)
                if self?.spills[id]?.generation == generation { self?.spills[id] = nil }
                guard let hosted, let i = hosted.indexByID[id] else { return }
                // Only the bodies that were saved: an update that landed during the save
                // brought new ones, which stay (the next update or window pass spills them).
                guard hosted.transactions[i].requestBody == req,
                      hosted.transactions[i].responseBody == resp else { return }
                hosted.transactions[i].requestBody = nil
                hosted.transactions[i].responseBody = nil
                hosted.transactions[i].bodiesEvicted = true
            }
            spills[id] = (generation, task)
        }

        /// Publishes coalesced upserts every 50ms, bodies stripped.
        private func scheduleFlush() {
            guard flushTask == nil else { return }
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.flushTask = nil
                for (id, hosted) in self.sessions where !hosted.outgoingOrder.isEmpty {
                    let batch = hosted.outgoingOrder.compactMap { hosted.outgoing[$0]?.strippingBodies() }
                    hosted.outgoing.removeAll(keepingCapacity: true)
                    hosted.outgoingOrder.removeAll(keepingCapacity: true)
                    self.bus.publish(NetworkArea.transactionsTopic(id), batch, droppable: true)
                }
            }
        }

        func transactions(_ id: UUID) -> [NetworkTransaction] {
            sessions[id]?.transactions.map { $0.strippingBodies() } ?? []
        }

        func list() -> [Session] {
            sessions.map { id, hosted in
                Session(id: id, name: hosted.device.displayModel, device: hosted.device,
                        state: hosted.engine.state, transactionCount: hosted.transactions.count)
            }.sorted { $0.id.uuidString < $1.id.uuidString }
        }

        /// The newest matching transactions of one capture (or of all of them), oldest first.
        func search(_ p: SearchParams) throws -> [Row] {
            let searched: [(UUID, Hosted)] = try p.id.map { [($0, try session($0))] } ?? sessions.map { ($0.key, $0.value) }
            let search = NetworkSearch(host: p.host, method: p.method, status: p.status ?? [],
                                       failed: p.failed ?? false, idPrefix: p.idPrefix)
            let limit = min(max(p.limit ?? NetworkArea.defaultSearchRows, 1), NetworkArea.maxSearchRows)
            var rows: [Row] = []
            for (id, hosted) in searched {
                // Each capture is in arrival order: its newest `limit` matches are enough.
                var kept = 0
                for txn in hosted.transactions.reversed() where search.matches(txn) {
                    rows.append(Row(txn, session: id))
                    kept += 1
                    if kept == limit { break }
                }
            }
            rows.sort { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }
            return Array(rows.suffix(limit))
        }

        /// nil when the capture or the transaction is unknown (closed, cleared), so the client can
        /// tell "unavailable" from an empty body.
        func bodies(_ p: BodyParams) async -> Bodies? {
            guard let hosted = sessions[p.id], let i = hosted.indexByID[p.transaction] else { return nil }
            let txn = hosted.transactions[i]
            if txn.requestBody != nil || txn.responseBody != nil {
                return Bodies(request: txn.requestBody, response: txn.responseBody)
            }
            guard txn.bodiesEvicted, let cache = bodyCache else { return Bodies() }
            let loaded = await cache.load(p.transaction)
            return Bodies(request: loaded.req, response: loaded.resp)
        }

        /// One transaction with its headers and bodies (spilled ones read back). nil when the
        /// capture or the transaction is unknown.
        func transaction(_ p: BodyParams) async -> NetworkTransaction? {
            guard let bodies = await bodies(p), let hosted = sessions[p.id], let i = hosted.indexByID[p.transaction] else {
                return nil
            }
            var txn = hosted.transactions[i]
            txn.requestBody = bodies.request
            txn.responseBody = bodies.response
            txn.bodiesEvicted = false
            return txn
        }

        /// HAR of everything captured. Bodies still in memory are included, spilled ones are
        /// not, the same as exporting from the app's list.
        func har(_ id: UUID) -> Data? {
            guard let hosted = sessions[id] else { return nil }
            return HARExport.data(from: hosted.transactions)
        }

        func clear(_ id: UUID) {
            guard let hosted = sessions[id] else { return }
            hosted.transactions.removeAll()
            hosted.indexByID.removeAll()
            hosted.outgoing.removeAll()          // queued upserts would bring cleared rows back
            hosted.outgoingOrder.removeAll()
        }

        func close(_ id: UUID) -> Bool {
            guard let hosted = sessions.removeValue(forKey: id) else { return false }
            hosted.engine.close()
            bus.clearRetained(NetworkArea.stateTopic(id))
            let deviceID = hosted.device.id
            if !sessions.values.contains(where: { $0.device.id == deviceID }), let ctx = contexts.removeValue(forKey: deviceID) {
                ctx.stop()
            }
            return true
        }

        func session(_ id: UUID) throws -> Hosted {
            guard let hosted = sessions[id] else { throw RPCError.failed("No network capture \(id.uuidString).") }
            return hosted
        }

        func reapOrphans(now: Date = Date()) {
            for (id, hosted) in sessions {
                if bus.hasSubscribers(NetworkArea.transactionsTopic(id)) {
                    hosted.unwatchedSince = nil
                } else if let since = hosted.unwatchedSince {
                    if now.timeIntervalSince(since) >= orphanTimeout {
                        DaemonLog.info("closing network capture \(id): unwatched for \(orphanTimeout)s")
                        _ = close(id)
                    }
                } else {
                    hosted.unwatchedSince = now
                }
            }
        }
    }

    /// Installs the area and returns its captures, which `OverridesArea` seeds rules from.
    /// Without a `controller`, the area makes one on the persisted mode.
    @MainActor
    @discardableResult
    static func install(on server: DaemonServer, captures: Captures? = nil,
                        controller: NetworkModeController? = nil,
                        interceptServices: @escaping () -> InterceptServices? = { nil }) -> Captures {
        let orphan = DaemonDefaults.orphanTimeout
        let captures = captures ?? Captures(bus: server.bus, orphanTimeout: orphan)
        captures.interceptServices = interceptServices
        let controller = controller ?? NetworkModeController(captures: captures, bus: server.bus)
        server.keep(captures)
        server.keep(controller)
        // A pending device teardown also counts: quitting then would strand a device proxy.
        server.addBusyCheck("network") { captures.isBusy || !DeviceReleaseGate.shared.pendingSerials.isEmpty }
        server.keep(TaskBox(Task { @MainActor [weak captures] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(60, max(1, captures?.orphanTimeout ?? 60) / 4)))
                captures?.reapOrphans()
            }
        }))

        let r = server.router
        r.register("network.open", "Opens (or attaches to, by id) a network capture for a device.",
                   params: OpenParams.self,
                   takes: .object(["id": .uuid, "device": .device],
                                  optional: ["sourceID": .string, "package": .string, "autoStart": .boolean]),
                   returns: .object(["id": .uuid, "state": .networkCaptureState, "existed": .boolean])) { p, _ in
            try DaemonInput.device(p.device)
            try DaemonInput.package(p.package)
            return await captures.openWhenIdle(p)
        }
        r.register("network.select", "Chooses a capture source (agent) and starts it.", params: SelectParams.self,
                   takes: .object(["id": .uuid, "sourceID": .string], optional: ["package": .string]), returns: .empty) { p, _ in
            try DaemonInput.package(p.package)
            try await captures.selectWhenIdle(p.id, sourceID: p.sourceID, package: p.package)
            return RPCEmpty()
        }
        r.register("network.mode", "The network inspection mode: agent or mitm.",
                   takes: .empty, returns: .networkMode) { (_: RPCEmpty, _) in
            await controller.state
        }
        r.register("network.setMode", "Sets the network inspection mode, and stops the captures it no longer offers.",
                   params: SetModeParams.self, takes: .object(["mode": .enumeration(["agent", "mitm"])]),
                   returns: .empty) { p, _ in
            let mode = try NetworkArea.mode(wireName: p.mode)
            await controller.setMode(mode)
            return RPCEmpty()
        }
        // COPY-PENDING: the approved summary does not name the iOS Simulator; proposed:
        // "Installs Jaca's certificate on the capture's device: into the system store when the
        // device is rooted, into the keychain of an iOS Simulator, otherwise into Download for a
        // manual install."
        r.register("network.installCA", "Installs Jaca's certificate on the capture's device: into the system store when the device is rooted, otherwise into Download for a manual install.",
                   params: IDParams.self, takes: .sessionID, returns: .networkInstallCAResult) { p, _ in
            try await captures.installCA(p.id)
        }
        r.register("network.rebootSimulator", "iOS Simulator: reboots it, so its apps trust a newly installed certificate.",   // COPY-PENDING
                   params: IDParams.self, takes: .sessionID, returns: .empty) { p, _ in
            try await captures.rebootSimulator(p.id); return RPCEmpty()
        }
        r.register("network.reopenChooser", "Stops and returns to source selection.", params: IDParams.self,
                   takes: .sessionID, returns: .empty) { p, _ in
            try await MainActor.run { try captures.session(p.id).engine.reopenChooser() }; return RPCEmpty()
        }
        r.register("network.stop", "Stops capturing.", params: IDParams.self,
                   takes: .sessionID, returns: .empty) { p, _ in
            try await MainActor.run { try captures.session(p.id).engine.stop() }; return RPCEmpty()
        }
        r.register("network.restartForInterceptChange", "Restarts the running source so it picks up changed override settings.",
                   params: IDParams.self, takes: .sessionID, returns: .empty) { p, _ in
            try await MainActor.run { try captures.session(p.id).engine.restartForInterceptChange() }; return RPCEmpty()
        }
        r.register("network.openBrowser", "This Mac: opens the capture's Chrome window again after it was closed.",
                   params: IDParams.self, takes: .sessionID, returns: .empty) { p, _ in
            try await MainActor.run { try captures.session(p.id).engine.openBrowser() }; return RPCEmpty()
        }
        r.register("network.relaunchToAttach", "iOS Simulator: relaunches the app to put the agent back.",
                   params: IDParams.self, takes: .sessionID, returns: .empty) { p, _ in
            try await MainActor.run { try captures.session(p.id).engine.relaunchToAttach() }; return RPCEmpty()
        }
        r.register("network.clearProxyNeedsSetup", "Dismisses the proxy setup prompt.", params: IDParams.self,
                   takes: .sessionID, returns: .empty) { p, _ in
            try await MainActor.run { try captures.session(p.id).engine.clearProxyNeedsSetup() }; return RPCEmpty()
        }
        r.register("network.list", "", takes: .empty, returns: .array(.networkSession)) { (_: RPCEmpty, _) in
            await captures.list()
        }
        r.register("network.transactions", "Every captured transaction, bodies omitted.", params: IDParams.self,
                   takes: .sessionID, returns: .array(.networkTransaction), concurrent: true) { p, _ in
            await captures.transactions(p.id)
        }
        r.register("network.search", "", params: SearchParams.self,
                   takes: .object(optional: [
                       "id": .uuid, "host": .string, "method": .string, "status": .array(.networkStatusRange),
                       "failed": .boolean, "idPrefix": .string, "limit": .integer,
                   ]),
                   returns: .array(.networkRow), concurrent: true) { p, _ in
            try await captures.search(p)
        }
        r.register("network.transaction", "", params: BodyParams.self,
                   takes: .object(["id": .uuid, "transaction": .uuid]),
                   returns: .nullable(.networkTransaction), concurrent: true) { p, _ in
            await captures.transaction(p)
        }
        r.register("network.body", "A transaction's request and response bodies (base64).", params: BodyParams.self,
                   takes: .object(["id": .uuid, "transaction": .uuid]),
                   returns: .nullable(.object(optional: ["request": .bytes, "response": .bytes])), concurrent: true) { p, _ in
            await captures.bodies(p)
        }
        r.register("network.exportHAR", "The capture as HAR JSON (base64 data), or null.", params: IDParams.self,
                   takes: .sessionID, returns: .nullable(.bytes), concurrent: true) { p, _ in
            await captures.har(p.id)
        }
        r.register("network.clear", "Forgets captured transactions.", params: IDParams.self,
                   takes: .sessionID, returns: .empty) { p, _ in
            await captures.clear(p.id); return RPCEmpty()
        }
        r.register("network.close", "Stops and closes a capture. Returns whether it existed.", params: IDParams.self,
                   takes: .sessionID, returns: .boolean) { p, _ in
            await captures.close(p.id)
        }
        r.describeTopic("net.txns.<id>", "Coalesced transaction upserts (~50ms), bodies omitted. Dropped for a slow client; resync with network.transactions. Data: [NetworkTransaction].")
        r.describeTopic("net.state.<id>", "The capture's state. Data: NetworkCaptureState.", retained: true)
        r.describeTopic(NetworkModeController.topic, "The network inspection mode. Data: {mode, switching}.", retained: true)   // COPY-PENDING
        return captures
    }
}

extension NetworkArea.Session {
    private enum CodingKeys: String, CodingKey { case id, name, device, state, transactionCount }

    /// Tolerant: only the id and the device are required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let device = try c.decode(Device.self, forKey: .device)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? device.displayModel,
                  device: device,
                  state: (try? c.decodeIfPresent(NetworkCaptureState.self, forKey: .state)) ?? NetworkCaptureState(),
                  transactionCount: (try? c.decodeIfPresent(Int.self, forKey: .transactionCount)) ?? 0)
    }
}

extension NetworkArea.Row {
    private enum CodingKeys: String, CodingKey {
        case id, session, method, url, host, statusCode, error, startedAt, durationMs
        case requestBytes, responseBytes, overriddenByRuleID
    }

    /// Tolerant: only the two ids are required.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        session = try c.decode(UUID.self, forKey: .session)
        method = (try? c.decodeIfPresent(String.self, forKey: .method)) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        host = (try? c.decodeIfPresent(String.self, forKey: .host)) ?? ""
        statusCode = try? c.decodeIfPresent(Int.self, forKey: .statusCode)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        startedAt = (try? c.decodeIfPresent(Date.self, forKey: .startedAt)) ?? Date(timeIntervalSince1970: 0)
        durationMs = try? c.decodeIfPresent(Int.self, forKey: .durationMs)
        requestBytes = (try? c.decodeIfPresent(Int.self, forKey: .requestBytes)) ?? 0
        responseBytes = (try? c.decodeIfPresent(Int.self, forKey: .responseBytes)) ?? 0
        overriddenByRuleID = try? c.decodeIfPresent(UUID.self, forKey: .overriddenByRuleID)
    }
}

/// The installers `network.installCA` and `network.rebootSimulator` run. Tests pass fakes, so
/// they never touch a device.
struct NetworkCAInstall: Sendable {
    /// (adb, serial, PEM file) -> the headless rooted install.
    var androidRooted: @Sendable (URL, String, URL) async -> HeadlessCAOutcome
    /// (adb, serial, PEM file) -> whether the copy to Download worked.
    var androidPush: @Sendable (URL, String, URL) async -> Bool
    /// (UDID, PEM text).
    var simulatorInstall: @Sendable (String, String) async -> Result<Void, SimulatorCAError>
    var simulatorReboot: @Sendable (String) async -> Result<Void, SimulatorCAError>

    static let live = NetworkCAInstall(
        androidRooted: { await AndroidCACertInstaller.installRootedHeadless(adbURL: $0, serial: $1, caPEM: $2) },
        androidPush: { await AndroidCACertInstaller.pushForManualInstall(adbURL: $0, serial: $1, caPEM: $2) },
        simulatorInstall: { await SimulatorCAInstaller().install(udid: $0, caPEM: $1) },
        simulatorReboot: { await SimulatorCAInstaller().reboot(udid: $0) })
}
