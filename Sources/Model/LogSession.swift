import Foundation
import Observation

/// Thread-safe hand-off buffer between the background stream consumer and the
/// main-actor flush loop, so we never mutate `@Observable` state per line.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [LogLine] = []

    func append(_ line: LogLine) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    /// Drains up to `max` lines (oldest first), leaving any remainder for the next
    /// tick so a big burst is spread across flushes instead of one main-thread hit.
    func drain(max: Int) -> [LogLine] {
        lock.lock(); defer { lock.unlock() }
        if lines.count <= max {
            let out = lines
            lines.removeAll(keepingCapacity: true)
            return out
        }
        let out = Array(lines.prefix(max))
        lines.removeFirst(max)
        return out
    }
}

/// Monotonic, thread-safe id source. The session stamps every line (and marker)
/// with it so ids stay unique + ordered across stream reconnects (each `LogSource`
/// restart would otherwise reset its own seq to 0).
final class SeqCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private let stride: UInt64
    /// `stride` leaves room between consecutive lines so a line the prettifier splits into
    /// several entries (metadata head / JSON body / trailing) can get distinct, in-order
    /// sub-seqs (`base, base+1, …`) without colliding with the next line — keeping `seq`
    /// strictly increasing for the front-trim and persistence ordering. Far more than the
    /// ≤ 3 parts a split ever produces.
    init(start: UInt64 = 0, stride: UInt64 = 8) { self.value = start; self.stride = stride }
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; let v = value; value &+= stride; return v }
}

/// One tab: a single running (or stopped) log stream bound to a device + filter,
/// with an editable display name. Incoming lines accumulate off-main and are
/// coalesced into the observed `visible` slice on a ~30ms timer to stay smooth
/// under thousands of lines/sec.
@MainActor
@Observable
final class LogSession: WorkspaceTab {
    let id = UUID()
    var displayName: String { didSet { onStateChanged?() } }
    let device: Device

    /// Called when persisted state (filter/package/name) changes, so the open-tabs
    /// snapshot is saved immediately rather than only on quit.
    var onStateChanged: (() -> Void)?

    /// Shared per-device state (installed-app list), set by AppModel and reused
    /// across all tabs for this device — see `DeviceContext`.
    var deviceContext: DeviceContext?

    private(set) var filter: LogFilter
    private(set) var isRunning = false
    private(set) var isConnecting = false
    private(set) var visible: [LogLine] = []
    /// Maps the virtualized list's fixed-height **display rows** to `visible` entries:
    /// a log with embedded `\n`s spans several rows. Kept in lockstep with `visible`
    /// so the table can render multi-line logs without losing the uniform-row fast path.
    private(set) var displayMap = DisplayLineMap()
    /// Cumulative display rows trimmed off the front (the row-unit analogue of
    /// `droppedCount`), so the list can shift the viewport to stay put through a trim.
    private(set) var droppedDisplayRows = 0
    private(set) var totalCount = 0
    private(set) var droppedCount = 0
    /// Bumped whenever `visible` is replaced wholesale (clear / filter change) — as
    /// opposed to an append. The virtualized list uses it to choose a full reload vs
    /// a cheap row-count update.
    private(set) var listEpoch = 0
    /// Seqs of detected crashes (FATAL EXCEPTION / native fatal), oldest→newest.
    private(set) var crashSeqs: [UInt64] = []
    /// Which crash the up/down navigation is currently on (nil = none selected yet).
    private(set) var crashCursor: Int?
    var crashCount: Int { crashSeqs.count }
    var lastCrashSeq: UInt64? { crashSeqs.last }
    /// Set to a line seq to request the list scroll to it (crash navigation).
    var scrollTarget: UInt64?
    var followTail = true
    var statusMessage: String?

    /// Seqs of prettified response bodies the user has collapsed to a single line
    /// (double-click toggles). Default is expanded; only huge payloads are usually
    /// folded. Read by the render path via `displayMessage`/`effectiveLineCount`.
    private(set) var collapsedBodies: Set<UInt64> = []
    /// Stateful detector that prettifies JSON response bodies as lines stream past.
    /// Fed every line in `flush` (in arrival order) so the two-log "split" shape pairs.
    private var bodyPrettifier = LogBodyPrettifier()

    /// Invoked each time the stream starts (so history recording works whether the
    /// tab is auto-started or started later by the user).
    var onStarted: (() -> Void)?

    /// Subtitle for the tab/strip: device model + active filter summary.
    var subtitle: String {
        var parts = [device.displayModel]
        if !filter.packageLabel.isEmpty { parts.append(filter.packageLabel) }
        if !filter.query.isEmpty { parts.append("“\(filter.query)”") }
        if filter.minLevel != .verbose { parts.append("≥\(filter.minLevel.short)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Display rows (multi-line)

    /// Total fixed-height rows the list renders (≥ `visible.count`; multi-line logs
    /// contribute more than one).
    var displayRowCount: Int { displayMap.totalRows }

    /// The `(logIndex, subLine)` a display row maps to. Callers gate on `displayRowCount`.
    func locate(displayRow row: Int) -> (log: Int, sub: Int) { displayMap.locate(row: row) }

    /// First display row of a `visible` entry (for crash scroll-to).
    func firstDisplayRow(ofLog i: Int) -> Int { displayMap.firstRow(ofLog: i) }

    /// The contiguous display-row range a `visible` entry occupies (for selection).
    func displayRowRange(ofLog i: Int) -> ClosedRange<Int> { displayMap.rows(ofLog: i) }

    /// The `visible` index of a line by its seq (crash navigation), or nil.
    func logIndex(forSeq seq: UInt64) -> Int? { visible.firstIndex { $0.seq == seq } }

    /// The text a `visible` entry currently renders as: the compact one-liner when a
    /// prettified body is collapsed, otherwise the full (expanded) message.
    func displayMessage(_ line: LogLine) -> String {
        if let compact = line.bodyCompact, collapsedBodies.contains(line.seq) { return compact }
        return line.message
    }

    /// Display-row count for a `visible` entry, honouring a collapsed body.
    private func effectiveLineCount(_ line: LogLine) -> Int {
        LogTextLines.count(displayMessage(line))
    }

    /// Toggles a prettified body between expanded (multi-line) and collapsed (one line).
    /// No-op for non-body lines. The entry's first row keeps its position, so a collapse
    /// just folds the rows below it upward like a disclosure; a rebuilt display map +
    /// epoch bump tells the list to reload.
    func toggleBodyCollapsed(logIndex i: Int) {
        guard i >= 0, i < visible.count, visible[i].bodyCompact != nil else { return }
        let seq = visible[i].seq
        if !collapsedBodies.insert(seq).inserted { collapsedBodies.remove(seq) }
        displayMap.rebuild(lineCounts: visible.map { effectiveLineCount($0) })
        listEpoch &+= 1
    }

    /// Maps a set of selected display rows back to the unique `visible` entries they
    /// belong to, in order — so selecting any sub-line of a multi-line log copies the
    /// whole entry exactly once.
    func logIndices(forDisplayRows rows: IndexSet) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for r in rows where r < displayMap.totalRows {
            let li = displayMap.locate(row: r).log
            if seen.insert(li).inserted { out.append(li) }
        }
        return out
    }

    /// Builds the primary source for the current target. The bundle id matters only
    /// for physical iOS, where an empty id streams the whole-device syslog and a
    /// real id launches that app under devicectl's console (full, un-redacted logs).
    private let makeSource: @Sendable (_ bundleID: String) -> LogSource?
    private var source: LogSource?
    /// Set when the primary source is being swapped on purpose (iOS app-target
    /// change), so the reconnect loop skips the "stream lost" warning.
    private var swappingSource = false
    /// Optional secondary source that captures the targeted app's stdout/print
    /// (simulator `--console-pty`). Built per-bundle, so it's a factory taking the
    /// current package; nil on platforms without a stdout tap (Android, real iOS).
    private let makeConsoleSource: (@Sendable (_ bundleID: String) -> LogSource?)?
    private var consoleSource: LogSource?
    private let seq = SeqCounter()
    let adbURL: URL
    private let onPersist: (@Sendable (UUID, [LogLine]) -> Void)?

    // Package liveness, for death/restart markers.
    private var appWasAlive = false
    private var sawAppAlive = false

    private var ring: [LogLine] = []
    // Virtualized rendering makes display cost independent of buffer size, so we keep
    // a large scrollback and drop far less. (Memory ≈ this × ~300 B.)
    private let ringCap = 500_000
    private let maxPerFlush = 4_000           // bound main-thread work per tick
    private var compiledRegex: NSRegularExpression?
    private var recomputeToken = 0
    /// Every PID the filtered package has had this session. We accumulate and never
    /// clear it, so a crashing/relaunching app keeps showing its logs (incl. the crash).
    private var accumulatedPids: Set<Int32> = []

    private let pending = LineBuffer()
    private var consumeTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pidTask: Task<Void, Never>?
    private var consoleTask: Task<Void, Never>?

    init(
        device: Device,
        makeSource: @escaping @Sendable (_ bundleID: String) -> LogSource?,
        adbURL: URL,
        filter: LogFilter = LogFilter(),
        displayName: String? = nil,
        makeConsoleSource: (@Sendable (_ bundleID: String) -> LogSource?)? = nil,
        onPersist: (@Sendable (UUID, [LogLine]) -> Void)? = nil
    ) {
        self.device = device
        self.makeSource = makeSource
        self.makeConsoleSource = makeConsoleSource
        self.adbURL = adbURL
        self.filter = filter
        self.onPersist = onPersist
        self.displayName = displayName ?? device.displayModel
        self.compiledRegex = filter.compiledRegex()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        statusMessage = nil
        onStarted?()
        startFlushLoop()
        restartPIDPollingIfNeeded()
        restartConsoleCaptureIfNeeded()
        consumeTask = Task.detached(priority: .utility) { [weak self] in
            await self?.consumeLoop()
        }
    }

    /// Connects the source and streams; if the stream ends while we're still running
    /// (device unplugged, adb restarted, …) it injects a reconnect marker and retries
    /// forever — automatic reconnection. Every line is re-stamped with our monotonic
    /// seq so ids stay unique across reconnects.
    private func consumeLoop() async {
        let buffer = pending, counter = seq
        var disconnected = false
        while await isRunning, !Task.isCancelled {
            guard let stream = await openStream() else {   // couldn't spawn the tool
                if !disconnected { injectMarker("✕ can’t reach \(device.displayModel) — retrying…"); disconnected = true }
                try? await Task.sleep(for: .seconds(2)); continue
            }
            if disconnected { injectMarker("✓ \(device.displayModel) reconnected"); disconnected = false }
            for await line in stream {
                var l = line; l.seq = counter.next(); buffer.append(l)
            }
            // stream ended
            guard await isRunning, !Task.isCancelled else { break }
            // A deliberate source swap (iOS app-target change) just stopped the old
            // source — reconnect immediately with the new target, no "lost" warning.
            if await takeSwappingSource() { continue }
            injectMarker("✕ log stream to \(device.displayModel) lost — reconnecting…")
            disconnected = true
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func openStream() -> AsyncStream<LogLine>? {
        let s = makeSource(filter.packageLabel)
        source = s
        return try? s?.start()
    }

    /// Consumes the intentional-swap flag (so the reconnect loop can tell a deliberate
    /// source switch from a real disconnect). Main-actor; called via `await`.
    private func takeSwappingSource() -> Bool {
        let v = swappingSource; swappingSource = false; return v
    }

    /// Injects a synthetic, always-visible marker line (thread-safe; callable off-main).
    nonisolated func injectMarker(_ message: String, critical: Bool = false) {
        var m = LogLine.marker(message, critical: critical)
        m.seq = seq.next()
        pending.append(m)
    }

    /// Navigate to the next crash (downward / newer). With nothing selected yet it
    /// jumps to the first; it wraps to the top after the last.
    func nextCrash() { moveCrash(forward: true) }
    /// Navigate to the previous crash (upward / older). With nothing selected it jumps
    /// to the last; it wraps to the bottom before the first.
    func previousCrash() { moveCrash(forward: false) }

    private func moveCrash(forward: Bool) {
        guard let target = Self.nextCrashIndex(cursor: crashCursor, count: crashSeqs.count, forward: forward)
        else { return }
        crashCursor = target
        followTail = false
        scrollTarget = crashSeqs[target]
    }

    /// Cycling crash index: nil + forward → first, nil + back → last; otherwise step
    /// and wrap. Returns nil when there are no crashes.
    nonisolated static func nextCrashIndex(cursor: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        if let c = cursor { return forward ? (c + 1) % count : (c - 1 + count) % count }
        return forward ? 0 : count - 1
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        source?.stop(); source = nil
        consoleSource?.stop(); consoleSource = nil
        consumeTask?.cancel(); consumeTask = nil
        flushTask?.cancel(); flushTask = nil
        pidTask?.cancel(); pidTask = nil
        consoleTask?.cancel(); consoleTask = nil
        flush(max: .max)  // drain everything that's left
        // Emit any response body still being reassembled across chunks (the stream ended
        // mid-body) so held fragments aren't lost.
        let leftover = bodyPrettifier.finalize()
        if !leftover.isEmpty {
            for var l in leftover { l.seq = seq.next(); pending.append(l) }
            flush(max: .max)
        }
    }

    func toggle() { isRunning ? stop() : connect() }

    /// Verifies the device is reachable (and, for Android, that a filtered package
    /// is installed) before starting the stream, surfacing a clear message if not.
    /// Used by restored/stopped tabs to (re)connect with feedback.
    func connect() {
        guard !isRunning, !isConnecting else { return }
        isConnecting = true
        statusMessage = nil
        Task { @MainActor in
            let available = await checkDeviceAvailable()
            guard available else {
                isConnecting = false
                statusMessage = deviceUnavailableMessage
                return
            }
            // Soft check: warn (but still connect) if a filtered package is missing.
            if device.platform == .android, !filter.packageLabel.isEmpty,
               await !isPackageInstalled(filter.packageLabel) {
                statusMessage = "App “\(filter.packageLabel)” isn’t installed on \(device.displayModel)."
            }
            isConnecting = false
            start()
        }
    }

    private var deviceUnavailableMessage: String {
        switch device.platform {
        case .android:
            return "\(device.displayModel) isn’t connected — plug it in and authorize USB debugging."
        case .iosSimulator:
            return "\(device.displayModel) isn’t booted — start the simulator and try again."
        case .iosDevice:
            return "\(device.displayModel) isn’t connected — plug it in and trust this Mac."
        }
    }

    private func checkDeviceAvailable() async -> Bool {
        switch device.platform {
        case .android:
            let r = try? await CommandRunner.run(adbURL, ["-s", device.id, "get-state"])
            return r?.exitCode == 0 && (r?.stdout.contains("device") ?? false)
        case .iosSimulator:
            // iOS uses xcrun, not adb — `adbURL` is the adb path when the Android SDK
            // is installed, which would make `adb simctl …` fail.
            let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["simctl", "list", "devices", "booted"])
            return r?.stdout.contains(device.id) ?? false
        case .iosDevice:
            let r = try? await CommandRunner.run(AppleToolchain.xcrun, ["devicectl", "list", "devices"], timeout: 12)
            return r?.stdout.contains(device.id) ?? false
        }
    }

    private func isPackageInstalled(_ package: String) async -> Bool {
        let r = try? await CommandRunner.run(adbURL, ["-s", device.id, "shell", "pm", "list", "packages", package])
        return r?.stdout.contains("package:\(package)") ?? false
    }

    /// Clears the in-app scrollback (does not touch the device buffer).
    func clear() {
        recomputeToken &+= 1   // invalidate any in-flight background recompute
        ring.removeAll(keepingCapacity: true)
        visible.removeAll(keepingCapacity: true)
        displayMap.removeAll()
        totalCount = 0
        droppedCount = 0
        droppedDisplayRows = 0
        crashSeqs.removeAll()
        crashCursor = nil
        collapsedBodies.removeAll()
        bodyPrettifier = LogBodyPrettifier()   // forget any half-seen BODY START pair
        listEpoch &+= 1
    }

    /// Clears the device-side logcat buffer too (`adb logcat -c`).
    func clearDeviceBuffer() {
        clear()
        let url = adbURL, serial = device.id
        Task.detached { await AndroidLogSource.clearBuffer(adbURL: url, serial: serial) }
    }

    // MARK: - Filtering

    func setMinLevel(_ level: LogLevel) { mutateFilter { $0.minLevel = level } }
    func setRegex(_ on: Bool) { mutateFilter { $0.isRegex = on } }
    func setQuery(_ text: String) { mutateFilter { $0.query = text } }
    func setHideSystemLogs(_ on: Bool) { mutateFilter { $0.hideSystemLogs = on } }

    /// Applies the global message-exclusion rules and re-filters (no persist callback —
    /// the rules live in `LogExclusionStore`, not the per-tab descriptor).
    func applyExclusions(_ rules: [LogExcludeRule]) {
        filter.exclusions = rules
        compiledRegex = filter.compiledRegex()
        recomputeVisible()
    }

    /// Sets the package filter: stores the label and (re)starts PID polling so the
    /// filter survives the app being killed/relaunched (PIDs change).
    func setPackage(_ package: String) {
        accumulatedPids.removeAll()   // new target → forget the previous app's PIDs
        appWasAlive = false; sawAppAlive = false
        mutateFilter {
            $0.packageLabel = package
            switch device.platform {
            case .android, .iosSimulator:
                // Both filter by PID — the bundle id never appears as the process name
                // on iOS, but the unified log carries the process id (resolved below).
                $0.pids = package.isEmpty ? nil : []
                $0.processNameQuery = ""
            case .iosDevice:
                // The *source itself* is swapped per target (whole-device passive stream
                // vs. devicectl-console launch of the bundle), so no per-line LogFilter
                // process query is needed. The label is the app's bundle id.
                $0.processNameQuery = ""
                $0.pids = nil
            }
        }
        restartPIDPollingIfNeeded()
        restartConsoleCaptureIfNeeded()
        restartPrimaryForTargetChange()
    }

    /// Physical iOS swaps its *primary* source when the targeted app changes (unlike
    /// Android/simulator, which keep one source and filter on top): an empty target →
    /// whole-device passive LoggingSupport stream; a bundle id → a devicectl-console
    /// launch of that app (un-redacted os_log + print()). Stopping the current source
    /// lets the reconnect loop respawn the right one; each source emits its own marker.
    private func restartPrimaryForTargetChange() {
        guard isRunning, device.platform == .iosDevice else { return }
        swappingSource = true
        source?.stop()
    }

    private func mutateFilter(_ change: (inout LogFilter) -> Void) {
        change(&filter)
        compiledRegex = filter.compiledRegex()
        recomputeVisible()
        onStateChanged?()   // persist filter/package changes right away
    }

    /// Re-filters the whole ring off the main thread (it can be 100k lines), then
    /// assigns on main — so changing the level/query/package never freezes the UI.
    /// A token discards stale results; a catch-up pass re-adds lines that streamed
    /// in while the background filter ran.
    private func recomputeVisible() {
        recomputeToken &+= 1
        let token = recomputeToken
        let snapshot = ring
        let f = filter
        let lastSeq = snapshot.last?.seq
        Task.detached(priority: .userInitiated) {
            let regex = f.compiledRegex()
            let result = snapshot.filter { f.matches($0, regex: regex) }
            await MainActor.run { [weak self] in
                guard let self, token == self.recomputeToken else { return }
                var out = result
                if let lastSeq {
                    for line in self.ring where line.seq > lastSeq
                        && self.filter.matches(line, regex: self.compiledRegex) {
                        out.append(line)
                    }
                } else {
                    out = self.ring.filter { self.filter.matches($0, regex: self.compiledRegex) }
                }
                self.visible = out
                self.displayMap.rebuild(lineCounts: out.map { self.effectiveLineCount($0) })
                self.listEpoch &+= 1
            }
        }
    }

    // MARK: - Internals

    private func startFlushLoop() {
        flushTask = Task { [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                self.flush()
            }
        }
    }

    private func flush(max: Int = 4_000) {
        let drained = pending.drain(max: max)
        guard !drained.isEmpty else { return }
        // Auto-prettify detected JSON response bodies before they're stored, so the ring,
        // re-filtering and history all see the expanded form. Gated per flush, so turning
        // the toggle off only affects subsequent lines (already-stored lines stay as-is).
        // An inline body splits into several entries (so the JSON is its own copyable
        // line); each split part gets a distinct sub-seq within the slot the SeqCounter
        // reserved for the original, keeping seq order intact for trim + persistence.
        var batch: [LogLine]
        if LogBodyPrettifyStore.shared.enabled {
            batch = []
            batch.reserveCapacity(drained.count)
            for original in drained {
                let parts = bodyPrettifier.transform(original)
                for (k, p) in parts.enumerated() {
                    var pp = p; pp.seq = original.seq &+ UInt64(k); batch.append(pp)
                }
            }
        } else {
            batch = drained
        }
        onPersist?(id, batch)

        ring.append(contentsOf: batch)
        totalCount += batch.count

        if ring.count > ringCap {
            let overflow = ring.count - ringCap
            ring.removeFirst(overflow)
            droppedCount += overflow
            let minSeq = ring.first?.seq ?? 0
            var drop = 0
            while drop < visible.count && visible[drop].seq < minSeq { drop += 1 }
            if drop > 0 {
                visible.removeFirst(drop)
                droppedDisplayRows += displayMap.removeFirst(drop)
            }
        }
        for line in batch where filter.matches(line, regex: compiledRegex) {
            visible.append(line)
            displayMap.append(lineCount: effectiveLineCount(line))
            if CrashDetector.isCrash(line) {
                crashSeqs.append(line.seq)
                injectMarker("💥 \(CrashDetector.label(line))", critical: true)
            }
        }
    }

    /// Polls `pidof <package>` while a package filter is active, updating the PID
    /// set live so app restarts keep being captured.
    private func restartPIDPollingIfNeeded() {
        pidTask?.cancel(); pidTask = nil
        guard isRunning, !filter.packageLabel.isEmpty else { return }
        let url = adbURL, serial = device.id, package = filter.packageLabel
        let resolve: @Sendable () async -> Set<Int32>
        switch device.platform {
        case .android:
            resolve = { await AndroidLogSource.resolvePIDs(adbURL: url, serial: serial, package: package) }
        case .iosSimulator:
            resolve = { await SimulatorLogSource.resolvePIDs(udid: serial, bundleID: package) }
        case .iosDevice:
            return   // physical iOS uses substring matching, no pid polling
        }
        pidTask = Task { [weak self] in
            while !Task.isCancelled {
                let resolved = await resolve()
                guard let self, !Task.isCancelled else { return }

                // Mark death / restart so it's unmissable in the log.
                let isAlive = !resolved.isEmpty
                if isAlive {
                    if !self.appWasAlive && self.sawAppAlive {
                        let pids = resolved.sorted().map(String.init).joined(separator: ", ")
                        self.injectMarker("▶︎ \(package) restarted — pid \(pids)")
                    }
                    self.sawAppAlive = true
                } else if self.appWasAlive {
                    self.injectMarker("■ \(package) terminated")
                }
                self.appWasAlive = isAlive

                // Accumulate; never clear. If the app is dead (resolved empty) we keep
                // the known PIDs so its logs stay visible. New PIDs (relaunch) are added.
                let next = Self.accumulatePIDs(self.accumulatedPids, with: resolved)
                if next != self.accumulatedPids {
                    self.accumulatedPids = next
                    self.filter.pids = next
                    self.recomputeVisible()
                }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    /// Simulator stdout/print capture: when a bundle is targeted, launch it under a
    /// PTY (`simctl launch --console-pty`) and fold its stdout/stderr — the only place
    /// `print()`/`println` output appears — into this session alongside the OSLog
    /// stream. Re-targets when the package changes; (re)launches the app each time, by
    /// design. No-op on platforms without a stdout tap (`makeConsoleSource == nil`).
    private func restartConsoleCaptureIfNeeded() {
        consoleTask?.cancel(); consoleTask = nil
        consoleSource?.stop(); consoleSource = nil
        guard isRunning, let make = makeConsoleSource else { return }
        let bundle = filter.packageLabel
        guard !bundle.isEmpty, let src = make(bundle) else { return }
        guard let stream = try? src.start() else {
            injectMarker("✕ couldn’t launch \(bundle) for stdout/print capture")
            return
        }
        consoleSource = src
        injectMarker("▶︎ capturing stdout/print from \(bundle) (app relaunched)")
        let buffer = pending, counter = seq
        consoleTask = Task.detached(priority: .utility) {
            for await line in stream {
                var l = line; l.seq = counter.next(); buffer.append(l)
            }
        }
    }

    /// Accumulates an app's PIDs across restarts. An empty `resolved` (the app died /
    /// is being reinstalled) keeps the current set, so its logs are never hidden; new
    /// PIDs from a relaunch/reinstall are added.
    nonisolated static func accumulatePIDs(_ current: Set<Int32>, with resolved: Set<Int32>) -> Set<Int32> {
        resolved.isEmpty ? current : current.union(resolved)
    }

    /// Installed apps/packages on this device, for the filter dropdown.
    func installedApps() async -> [AppEntry] {
        await InstalledApps.list(for: device, adbURL: adbURL)
    }

    /// Last good app list (synchronous), so the picker shows something instantly while
    /// `installedApps()` refreshes — never a blank "No apps found" when we have a cache.
    func cachedApps() -> [AppEntry] {
        InstalledApps.cached(for: device)
    }

    // MARK: - Export

    func exportText() -> String {
        visible.map { $0.raw }.joined(separator: "\n")
    }
}
