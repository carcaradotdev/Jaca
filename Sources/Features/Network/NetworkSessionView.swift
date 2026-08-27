import SwiftUI
import Lemonade
import AppKit

/// Network-inspection tab: proxy toolbar, captured-transaction list, and a detail
/// pane (overview / headers / bodies / timing) for the selected transaction.
struct NetworkSessionView: View {
    @Bindable var session: NetworkSession
    @State private var showSetup = false
    @State private var showCAInstall = false
    @State private var showCompanionCA = false
    @State private var searchText = ""
    /// The rule being created/edited from the row context menu. The draft carries whether this
    /// is a new rule, so add-vs-update can't disagree with what's on screen.
    @State private var editingOverride: OverrideDraft?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            divider
            // Companion mode: always show the live setup status (linked? decrypting?) so opening
            // a companion device tells you whether it's set up and what to do if not.
            if session.captureMode == .companion {
                CompanionStatusBanner(session: session)
                    .contentShape(Rectangle())
                    .onTapGesture { showCompanionCA = true }
                    .help("Open HTTPS decryption setup")
                divider
            }
            if showCaptureChooser {
                captureChooser
            } else {
                if !session.transactions.isEmpty {
                    NetworkTimelineView(session: session)
                    divider
                }
                HSplitView {
                    transactionList
                        .frame(minWidth: 420, idealWidth: 560)
                    NetworkDetailView(transaction: session.selected)
                        .frame(minWidth: 320)
                }
            }
            divider
            statusBar
        }
        .background(LemonadeTheme.colors.background.bgDefault)
        .accessibilityIdentifier("networkSessionView")
        .onAppear {
            searchText = session.filterText
            // Auto-present the guided companion setup once when opening a companion device that
            // isn't decrypting yet — mirrors the proxy CA flow, focused on the companion app.
            if session.captureMode == .companion, !session.caReady, !session.didAutoShowCompanionSetup {
                session.didAutoShowCompanionSetup = true
                showCompanionCA = true
            }
        }
        // Proxy started but HTTPS isn't decrypting yet → guide the user to set up
        // the CA (or switch to Agent). One-shot: cleared once consumed.
        .onChange(of: session.proxyNeedsSetup) { _, needs in
            if needs { showSetup = true; session.proxyNeedsSetup = false }
        }
        .sheet(isPresented: $showSetup) {
            NetworkSetupSheet(
                session: session,
                onInstallCA: { showSetup = false; openCAInstall() },
                onSwitchToAgent: { showSetup = false; session.reopenModeChooser() }
            )
        }
        .sheet(isPresented: $showCAInstall) {
            if let installer = session.caInstaller {
                CAInstallSheet(installer: installer, onCancel: { session.cancelCAInstall() })
            }
        }
        .sheet(isPresented: $showCompanionCA) {
            CompanionCASheet(session: session)
        }
        .sheet(item: $editingOverride) { draft in
            if let overrides = session.overrides {
                OverrideEditorSheet(
                    rule: draft.rule, session: session, overrides: overrides, isNew: draft.isNew,
                    onSave: { saved in
                        withAnimation(.easeInOut(duration: 0.28)) { overrides.save(saved) }
                    }
                )
            }
        }
    }

    /// Probes the device, builds the installer, then presents the blocking sheet
    /// (which starts it on appear).
    private func openCAInstall() {
        Task {
            await session.prepareCAInstall()
            if session.caInstaller != nil { showCAInstall = true }
        }
    }

    private var divider: some View {
        Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
    }

    /// A fresh/stopped tab with no captured traffic and no chosen mode shows the
    /// capture-mode chooser instead of auto-starting — proxy mode must be picked
    /// deliberately because it reconfigures the device. Once a mode is chosen (incl.
    /// restored from a previous launch) the tab is ready and the user just presses play.
    private var showCaptureChooser: Bool {
        !session.hasSelectedMode && !session.isRunning && session.transactions.isEmpty
    }

    private var captureChooser: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing300) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            VStack(spacing: LemonadeTheme.spaces.spacing100) {
                LemonadeUi.Text(session.device.displayModel,
                                textStyle: LemonadeTypography.shared.bodyLargeMedium,
                                color: LemonadeTheme.colors.content.contentPrimary)
                LemonadeUi.Text("Choose how to capture traffic",
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }

            if session.isConnecting {
                HStack(spacing: LemonadeTheme.spaces.spacing200) {
                    ProgressView().controlSize(.small)
                    LemonadeUi.Text("Connecting…",
                                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                                    color: LemonadeTheme.colors.content.contentSecondary)
                }
            } else {
                VStack(spacing: LemonadeTheme.spaces.spacing200) {
                    let hasCompanion = session.availableSources.contains { $0.kind == .companion }
                    if hasCompanion {
                        LemonadeUi.Button(label: "Start companion capture", onClick: { session.startCompanionCapture() },
                                          leadingIcon: .smartphone, variant: .primary, type: .solid, size: .medium)
                            .fixedSize()
                        LemonadeUi.Text("Capture the whole device through the Jaca mobile app, attributed per app.",
                                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                        textAlign: .center,
                                        color: LemonadeTheme.colors.content.contentTertiary)
                            .frame(maxWidth: 420)
                        if session.isADBDevice {
                            LemonadeUi.Button(label: "Install CA automatically", onClick: { openCAInstall() },
                                              leadingIcon: .smartphone, variant: .neutral, type: .subtle, size: .small)
                                .fixedSize()
                            if let hint = rootHint {
                                LemonadeUi.Text(hint,
                                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                                textAlign: .center,
                                                color: LemonadeTheme.colors.content.contentTertiary)
                                    .frame(maxWidth: 420)
                            }
                        }
                    } else if session.companionCaptureEnabled && !session.agentAvailable && session.device.platform != .iosSimulator {
                        LemonadeUi.Text("Install the Jaca mobile app on this device to capture its traffic, then it appears here automatically.",
                                        textStyle: LemonadeTypography.shared.bodySmallRegular,
                                        textAlign: .center,
                                        color: LemonadeTheme.colors.content.contentSecondary)
                            .frame(maxWidth: 420)
                    }

                    if session.canPickAgentApp {
                        if hasCompanion {
                            LemonadeUi.Text("— or —",
                                            textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                                            color: LemonadeTheme.colors.content.contentTertiary)
                                .padding(.top, LemonadeTheme.spaces.spacing100)
                        }
                        NetworkAppPicker(session: session)
                        LemonadeUi.Text("Inspect one debuggable app in-process — call stacks behind each request, no CA.",
                                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                        textAlign: .center,
                                        color: LemonadeTheme.colors.content.contentTertiary)
                            .frame(maxWidth: 420)
                    } else if let reason = session.agentUnavailableReason {
                        // The in-process agent must never silently vanish: when a device that
                        // should support it can't (artifacts not built, adb missing, …), say why.
                        if hasCompanion {
                            LemonadeUi.Text("— or —",
                                            textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                                            color: LemonadeTheme.colors.content.contentTertiary)
                                .padding(.top, LemonadeTheme.spaces.spacing100)
                        }
                        agentUnavailableNotice(reason)
                    }
                }
            }

            if let status = session.statusMessage {
                LemonadeUi.Text(status,
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentCritical)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LemonadeTheme.colors.background.bgDefault)
        .accessibilityIdentifier("networkCaptureChooser")
    }

    /// Explains why the in-process agent option is unavailable, with the remedy (build
    /// commands / adb hint). Selectable so the user can copy the commands.
    private func agentUnavailableNotice(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                LemonadeUi.Text("In-process agent unavailable",
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentCaution)
            }
            .foregroundStyle(LemonadeTheme.colors.content.contentCaution)
            Text(reason)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LemonadeTheme.spaces.spacing300)
        .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
            .fill(LemonadeTheme.colors.background.bgCautionSubtle))
        .frame(maxWidth: 520)
        .accessibilityIdentifier("agentUnavailableNotice")
    }

    /// Surfaces the device's root status so the user knows whether the CA installs
    /// automatically or needs a tap on the device.
    private var rootHint: String? {
        guard session.isAndroid, let caps = session.deviceContext?.capabilities else { return nil }
        switch caps.root {
        case .rooted:
            return "Rooted / emulator — the CA installs into the system trust store automatically."
        case .notRooted:
            return caps.hasScreenLock
                ? "Not rooted — you'll confirm one certificate prompt on the device."
                : "Not rooted — set a screen lock on the device first (Android requires one for CA certs)."
        case .unknown:
            return nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            Button(action: { session.toggle() }) {
                Image(systemName: session.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(session.isRunning
                        ? LemonadeTheme.colors.content.contentCritical
                        : LemonadeTheme.colors.content.contentBrand)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                        .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
            }
            .buttonStyle(.plain)
            .help(session.isRunning ? "Stop capture" : "Start capture")
            .accessibilityIdentifier("netTransportButton")

            LemonadeUi.IconButton(icon: .trash, contentDescription: "Clear") { session.clear() }

            if session.canPickAgentApp {
                NetworkAppPicker(session: session)
            }

            LemonadeUi.SearchField(
                input: $searchText,
                onInputChanged: { session.filterText = $0 },
                placeholder: "Filter by URL, host, method…",
                onInputClear: { session.filterText = "" }
            )
            .frame(maxWidth: 360)

            OverridesToolbarButton(session: session)

            Spacer()

            modeBadge

            if let status = session.statusMessage {
                LemonadeUi.Text(status, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentSecondary, maxLines: 1)
            }
            LemonadeUi.IconButton(icon: .download, contentDescription: "Export HAR") { exportHAR() }
            // Proxy/CA setup only applies to a real ADB device capturing via the proxy.
            // Companion and agent modes need no proxy setup (the companion app installs its
            // own CA), and a companion-only device has no adb to set up — so hide it there.
            if session.showsProxySetup {
                LemonadeUi.Button(label: "Setup", onClick: { showSetup = true },
                                  leadingIcon: .circleInfo, variant: .neutral, type: .subtle, size: .small)
            }
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private var modeBadge: some View {
        let mode = session.captureMode
        let color: Color = mode == .agent ? LemonadeTheme.colors.content.contentBrand
            : (mode == .companion ? LemonadeTheme.colors.content.contentPositive
                                  : LemonadeTheme.colors.content.contentTertiary)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(mode.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        .help(mode == .agent ? "Capturing in-process via the agent (no proxy/CA)"
              : (mode == .companion ? "Streaming from the Jaca mobile companion app"
                                    : "Capturing via the MITM proxy"))
    }

    private func exportHAR() {
        guard let data = HARExport.data(from: session.transactions) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.displayName).har"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    private var transactionList: some View {
        VStack(spacing: 0) {
            columnHeader
            divider
            if session.filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.filtered) { txn in
                            NetworkRowView(txn: txn, selected: txn.id == session.selectedID,
                                           badge: overrideBadge(for: txn))
                                .contentShape(Rectangle())
                                .onTapGesture { session.selectedID = txn.id }
                                .contextMenu { rowMenu(for: txn) }
                        }
                    }
                }
            }
        }
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    // MARK: - Response overrides

    /// The row context menu. Items that can't work stay **visible and disabled** with a reason —
    /// a hidden item teaches the user nothing about why the feature isn't available here.
    @ViewBuilder
    private func rowMenu(for txn: NetworkTransaction) -> some View {
        let blocked = overrideUnavailableReason(for: txn)
        let existing = session.overrides?.matchingRule(forURL: txn.url, method: txn.method)

        Button(existing == nil ? "Override response…" : "Edit override “\(existing!.displayName)”") {
            session.selectedID = txn.id
            if let existing {
                editingOverride = .existing(existing)
            } else {
                seedOverride(from: txn)
            }
        }
        .disabled(blocked != nil)
        .help(blocked ?? "")

        if existing != nil {
            Button("Add another override…") {
                session.selectedID = txn.id
                seedOverride(from: txn)
            }
            .disabled(blocked != nil)
            .help(blocked ?? "")
        }

        Divider()

        Button("Copy URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(txn.url, forType: .string)
        }
        Button("Copy response body") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                txn.responseBody.flatMap { String(data: $0, encoding: .utf8) } ?? "", forType: .string)
        }

        Divider()

        Button("Filter by this host") {
            searchText = txn.host
            session.filterText = txn.host
        }
    }

    /// Why this row can't be overridden, or nil when it can.
    private func overrideUnavailableReason(for txn: NetworkTransaction) -> String? {
        guard session.overrides != nil else { return "Response overrides aren't available." }
        guard FeatureFlags.responseOverridesEnabled else {
            return "Turn on Response overrides in Settings first."
        }
        // Companion flow-metadata rows are "host:port", not HTTP requests.
        if OverrideMatching.facts(url: txn.url) == nil {
            return "This row is flow metadata, not an HTTP request."
        }
        if session.captureMode == .companion {
            return "Overrides apply to in-process agent capture. Companion capture will follow."
        }
        // The agent can only divert okhttp3 calls. `httpStack` is the only reliable signal —
        // `callStack` deliberately strips okhttp frames, so testing it here disabled every row.
        // Nil means "unknown" (older agent, or proxy capture), and must never block authoring.
        if let stack = txn.httpStack, stack != "okhttp3" {
            return "This request came from \(Self.stackLabel(stack)), not okhttp3 — Jaca can't divert it."
        }
        return nil
    }

    /// This tab's divert arming state, or `.idle` when it isn't an agent tab.
    private var armingState: AgentDivertCoordinator.State {
        guard let overrides = session.overrides, let target = session.interceptTarget else { return .idle }
        return overrides.arming(for: target)
    }

    /// Human-readable name for an agent-reported HTTP stack.
    private static func stackLabel(_ stack: String) -> String {
        switch stack {
        case "okhttp2":       return "okhttp2"
        case "urlconnection": return "HttpURLConnection"
        default:              return stack
        }
    }

    private func seedOverride(from txn: NetworkTransaction) {
        guard let overrides = session.overrides else { return }
        Task { @MainActor in
            let rule = await overrides.seed(from: txn, session: session)
            editingOverride = .new(rule)
        }
    }

    /// The row's override badge state, read from the shared model.
    private func overrideBadge(for txn: NetworkTransaction) -> NetworkRowView.OverrideBadge {
        guard let overrides = session.overrides, FeatureFlags.responseOverridesEnabled else { return .none }
        if let applied = overrides.appliedRule(for: txn) {
            return .applied(applied.displayName)
        }
        guard overrides.masterEnabled,
              let matching = overrides.matchingRule(forURL: txn.url, method: txn.method)
        else { return .none }

        // A saved rule that matches but isn't armed must not promise "applies on the next
        // request" — the tunnel may have failed to open, in which case nothing will happen.
        if case .failed(let detail) = armingState { return .blocked(detail) }

        // With no source running there's no transport to judge against — saying "can't run in
        // in-process agent capture" there is flatly wrong. "Applies on the next request" is the
        // honest reading of a saved rule.
        if session.hasRunningSource,
           let skip = overrides.blockedReason(forURL: txn.url, method: txn.method,
                                              transport: session.interceptTransport,
                                              capabilities: session.activeInterceptCapabilities) {
            return .blocked(skip.message)
        }
        return .willApply(matching.displayName)
    }

    private var columnHeader: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            headerCell(" ", width: 14)          // override badge gutter (hand-synced with the row)
            headerCell("Status", width: 52)
            headerCell("Method", width: 60)
            headerCell("Host", width: 150)
            headerCell("Path", width: nil)
            headerCell("Size", width: 70)
            headerCell("Time", width: 64)
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private func headerCell(_ title: String, width: CGFloat?) -> some View {
        LemonadeUi.Text(title.uppercased(),
                        textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                        color: LemonadeTheme.colors.content.contentTertiary, maxLines: 1)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing200) {
            Spacer()
            LemonadeUi.Icon(icon: .arrowLeftRight, contentDescription: nil, size: .large,
                            tint: LemonadeTheme.colors.content.contentTertiary)
            LemonadeUi.Text(session.isRunning ? "Waiting for traffic…" : "Capture stopped",
                            textStyle: LemonadeTypography.shared.bodySmallRegular,
                            color: LemonadeTheme.colors.content.contentSecondary)
            if session.captureMode == .companion {
                LemonadeUi.Text("Open the Jaca app on \(session.device.displayModel) and start capture — it connects automatically. Install the certificate in the app to decrypt HTTPS.",
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                textAlign: .center,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(LemonadeTheme.spaces.spacing400)
    }

    private var statusBar: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing300) {
            Circle()
                .fill(session.isRunning ? LemonadeTheme.colors.content.contentPositive
                                        : LemonadeTheme.colors.content.contentTertiary)
                .frame(width: 8, height: 8)
            metric("\(session.transactions.count) requests")
            Spacer()
            metric(session.device.displayModel)
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private func metric(_ text: String) -> some View {
        LemonadeUi.Text(text, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentSecondary, maxLines: 1)
    }
}

/// Picks the app to inspect in-process. Lists installed apps, tags the debuggable
/// ones ("agent" — those the in-process capture can attach to), and offers a
/// "Whole device (proxy)" option to fall back to the MITM proxy.
private struct NetworkAppPicker: View {
    let session: NetworkSession
    @State private var show = false
    @State private var apps: [AppEntry] = []
    @State private var debuggable: Set<String> = []
    @State private var loading = false
    @State private var loaded = false
    @State private var query = ""

    /// Prefer the shared per-device list (polled once per device); fall back to
    /// this tab's own one-shot load when no context is wired (e.g. in tests).
    private var appList: [AppEntry] { session.deviceContext?.apps ?? apps }
    private var debugSet: Set<String> { session.deviceContext?.debuggable ?? debuggable }
    private var isLoading: Bool {
        if let ctx = session.deviceContext { return !ctx.appsLoaded }
        return loading
    }

    var body: some View {
        Button(action: { show = true; onOpen() }) {
            HStack(spacing: 5) {
                Image(systemName: "ladybug").font(.system(size: 11, weight: .semibold))
                Text(buttonLabel).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(session.targetPackage == nil
                ? LemonadeTheme.colors.content.contentSecondary
                : LemonadeTheme.colors.content.contentBrand)
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .buttonStyle(.plain)
        .help("Choose an app to inspect in-process with the agent")
        .accessibilityIdentifier("netAppPicker")
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    private var buttonLabel: String {
        guard let p = session.targetPackage else { return "Inspect app" }
        return p.components(separatedBy: ".").last ?? p
    }

    private var sorted: [AppEntry] {
        let f = query.isEmpty ? appList : appList.filter {
            $0.id.localizedCaseInsensitiveContains(query) || ($0.name ?? "").localizedCaseInsensitiveContains(query)
        }
        return f.sorted { a, b in
            let da = debugSet.contains(a.id), db = debugSet.contains(b.id)
            if da != db { return da }                        // debuggable first
            if a.isUserApp != b.isUserApp { return a.isUserApp }
            return a.display.localizedCaseInsensitiveCompare(b.display) == .orderedAscending
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            TextField("Search apps…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(LemonadeTheme.spaces.spacing200)
                .accessibilityIdentifier("netAppSearch")
            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The whole-device fallback is the companion stream; only offer it when
                    // companion is actually available (it respects the feature flag, and an iOS
                    // Simulator has no companion — there the agent always needs a chosen app).
                    if session.availableSources.contains(where: { $0.kind == .companion }) {
                        row(title: "Whole device (companion)", subtitle: "capture all apps via the Jaca mobile app",
                            debug: false, selected: session.targetPackage == nil) { select(nil) }
                    }
                    if isLoading && appList.isEmpty {
                        ProgressView().padding(LemonadeTheme.spaces.spacing400).frame(maxWidth: .infinity)
                    }
                    ForEach(sorted) { app in
                        row(title: app.display, subtitle: app.name != nil ? app.id : nil,
                            debug: debugSet.contains(app.id),
                            selected: session.targetPackage == app.id) { select(app.id) }
                    }
                }
            }
        }
        .frame(width: 360, height: 420)
    }

    private func row(title: String, subtitle: String?, debug: Bool, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                        .font(.system(size: 12)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                            .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if debug {
                    Text("agent").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                }
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(LemonadeTheme.colors.content.contentBrand)
                }
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing300)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("netAppRow")
    }

    /// On open: nudge the shared per-device list to refresh, or do a one-shot
    /// load if there's no context.
    private func onOpen() {
        if let ctx = session.deviceContext { ctx.refreshApps() }
        else if !loaded { load() }
    }

    private func load() {
        loading = true
        Task { @MainActor in
            let result = await session.installedApps()
            apps = result
            loaded = true
            loading = false
            await withTaskGroup(of: (String, Bool).self) { group in
                for app in result where app.isUserApp {
                    group.addTask { (app.id, await session.isDebuggable(app.id)) }
                }
                for await (id, ok) in group where ok { debuggable.insert(id) }
            }
        }
    }

    private func select(_ id: String?) {
        show = false
        DispatchQueue.main.async { session.setTarget(id) }
    }
}

private struct NetworkRowView: View {
    let txn: NetworkTransaction
    let selected: Bool
    var badge: OverrideBadge = .none

    /// Whether an override touched (or would touch) this row. Computed in the model and passed
    /// in, never derived inside `body` — `filtered` can hold thousands of rows in a LazyVStack.
    enum OverrideBadge: Equatable {
        case none
        /// A rule produced this response.
        case applied(String)
        /// A rule matches, but this row predates it.
        case willApply(String)
        /// A rule matches but can't run on this transport.
        case blocked(String)
    }

    var body: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            badgeGutter
            Text(txn.statusText)
                .foregroundStyle(badge.isApplied
                                 ? LemonadeTheme.colors.content.contentCaution
                                 : NetworkFormatting.statusColor(txn))
                .fontWeight(.semibold)
                .frame(width: 52, alignment: .leading)
            Text(txn.method)
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .frame(width: 60, alignment: .leading)
            Text(txn.host)
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .frame(width: 150, alignment: .leading).lineLimit(1).truncationMode(.tail)
            Text(txn.path)
                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1).truncationMode(.middle)
            Text(NetworkFormatting.size(txn.responseBytes))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                .frame(width: 70, alignment: .leading)
            Text(NetworkFormatting.duration(txn.duration))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                .frame(width: 64, alignment: .leading)
        }
        .font(LogLevelStyle.mono(11))
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(rowBackground)
        .animation(.easeInOut(duration: 0.25), value: badge)
    }

    @ViewBuilder
    private var badgeGutter: some View {
        Group {
            switch badge {
            case .none:
                Color.clear
            case .applied:
                Image(systemName: "bolt.fill")
                    .foregroundStyle(LemonadeTheme.colors.content.contentCaution)
            case .willApply:
                Image(systemName: "bolt")
                    .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                    .opacity(0.6)
            case .blocked:
                Image(systemName: "bolt.slash")
                    .foregroundStyle(LemonadeTheme.colors.content.contentCaution)
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .frame(width: 14, alignment: .leading)
        .help(badge.tooltip)
    }

    private var rowBackground: Color {
        if selected { return LemonadeTheme.colors.interaction.bgSubtleInteractive }
        if badge.isApplied { return LemonadeTheme.colors.background.bgCautionSubtle.opacity(0.4) }
        return .clear
    }
}

private extension NetworkRowView.OverrideBadge {
    var isApplied: Bool { if case .applied = self { return true }; return false }

    var tooltip: String {
        switch self {
        case .none:                return ""
        case .applied(let name):   return "Answered by “\(name)” — the request never left the device"
        case .willApply(let name): return "Matches “\(name)” — applies on the next request"
        case .blocked(let reason): return reason
        }
    }
}

/// Live companion setup status. Tells the user, when they open a companion device, whether
/// it's actually linked and whether HTTPS is decrypting — and what to do if not. All three
/// signals come straight from the shared state (the registry's link/capture state and the
/// session's `caReady`), so the banner re-renders the moment any of them changes — no polling.
private struct CompanionStatusBanner: View {
    let session: NetworkSession
    private var linked: Bool { session.companionLinked }
    private var capturing: Bool { session.deviceCapturing }

    var body: some View {
        let decrypting = session.caReady
        return HStack(spacing: LemonadeTheme.spaces.spacing200) {
            Circle().fill(dot(decrypting)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                LemonadeUi.Text(title(decrypting),
                                textStyle: LemonadeTypography.shared.bodyXSmallSemiBold,
                                color: LemonadeTheme.colors.content.contentPrimary, maxLines: 1)
                LemonadeUi.Text(detail(decrypting),
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary, maxLines: 2)
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
        .background(LemonadeTheme.colors.background.bgElevated)
        .animation(.easeInOut(duration: 0.2), value: linked)
        .animation(.easeInOut(duration: 0.2), value: capturing)
        .animation(.easeInOut(duration: 0.2), value: decrypting)
    }

    private func dot(_ decrypting: Bool) -> Color {
        if !linked { return LemonadeTheme.colors.content.contentCritical }
        if !capturing || !decrypting { return LemonadeTheme.colors.content.contentCaution }
        return LemonadeTheme.colors.content.contentPositive
    }
    private func title(_ decrypting: Bool) -> String {
        if !linked { return "Companion offline" }
        if !capturing { return "Capture not running" }
        if !decrypting { return "Capturing — HTTPS not decrypted" }
        return "Decrypting HTTPS ✓"
    }
    private func detail(_ decrypting: Bool) -> String {
        if !linked { return "Open the Jaca app on \(session.device.displayModel) and start capture — it connects automatically." }
        if !capturing { return "The VPN isn't running — open the Jaca app on the device and start capture." }
        if !decrypting { return "Open the Jaca app and tap Install certificate to decrypt HTTPS — it confirms here automatically." }
        return "Capturing decrypted traffic from \(session.device.displayModel)."
    }
}
