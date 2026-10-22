import SwiftUI
import Lemonade
import AppKit

/// The active tab's content: filter/transport toolbar, the live log list, and a
/// status bar. Filtering, follow-tail, clear and export all act on the session.
struct LogSessionView: View {
    @Bindable var session: LogSession
    var isActive: Bool = true

    @State private var searchText = ""
    @State private var packageText = ""
    @State private var searchDebounce: Task<Void, Never>?
    @State private var packageDebounce: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            border
            if showConnectPrompt {
                connectPrompt
            } else {
                LogListView(session: session, isActive: isActive)
            }
            border
            StatusBarView(session: session)
        }
        .background(LemonadeTheme.colors.background.bgDefault)
        .accessibilityIdentifier("logSessionView")
        .onAppear {
            searchText = session.filter.query
            packageText = session.filter.packageLabel
        }
    }

    /// Restored/stopped tabs come back disconnected; offer an explicit reconnect.
    private var showConnectPrompt: Bool { !session.isRunning && session.totalCount == 0 }

    private var connectPrompt: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing300) {
            Spacer()
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            VStack(spacing: LemonadeTheme.spaces.spacing100) {
                LemonadeUi.Text(session.device.displayModel,
                                textStyle: LemonadeTypography.shared.bodyLargeMedium,
                                color: LemonadeTheme.colors.content.contentPrimary)
                LemonadeUi.Text("Disconnected",
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
                LemonadeUi.Button(label: "Try to Connect", onClick: { session.connect() },
                                  variant: .primary, type: .solid, size: .medium)
                    .fixedSize()   // size to the label instead of filling the width
            }
            if let status = session.statusMessage {
                LemonadeUi.Text(status,
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentCritical)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LemonadeTheme.colors.background.bgDefault)
        .accessibilityIdentifier("connectPrompt")
    }

    private var border: some View {
        Rectangle()
            .fill(LemonadeTheme.colors.border.borderNeutralLow)
            .frame(height: 1)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing200) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                transportButton
                clearMenu
                followButton
                if session.crashCount > 0 { crashBadge }
                Spacer()
                if let status = session.statusMessage {
                    LemonadeUi.Text(
                        status,
                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentCritical,
                        maxLines: 1
                    )
                }
                LemonadeUi.Button(label: "Copy format",
                                  onClick: { NotificationCenter.default.post(name: .openLogCopyFormat, object: nil) },
                                  leadingIcon: .settingsSlider, variant: .neutral, type: .subtle, size: .xSmall)
                    .fixedSize()
                LemonadeUi.IconButton(icon: .download, contentDescription: "Export") {
                    exportLog()
                }
            }
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                levelChips
                LemonadeUi.Chip(
                    label: ".*",
                    selected: session.filter.isRegex,
                    onChipClicked: { session.setRegex(!session.filter.isRegex) }
                )
                LemonadeUi.Chip(
                    label: "Prettify JSON",
                    selected: LogBodyPrettifyStore.shared.enabled,
                    onChipClicked: { LogBodyPrettifyStore.shared.enabled.toggle() }
                )
                .help("Auto-prettify endpoint response bodies (double-click a body to collapse it)")
                .accessibilityIdentifier("prettifyJSON")
                if session.device.platform != .android {
                    LemonadeUi.Chip(
                        label: "System logs",
                        selected: !session.filter.hideSystemLogs,
                        onChipClicked: { session.setHideSystemLogs(!session.filter.hideSystemLogs) }
                    )
                }
                searchField
                HStack(spacing: 2) {
                    packageField
                    PackagePicker(session: session, packageText: $packageText) { id in
                        packageText = id
                        session.setPackage(id)
                    }
                }
            }
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    /// Red crash counter with up/down navigation. ▲ goes to the previous (older) crash,
    /// ▼ to the next (newer); both cycle, and with nothing selected ▼ starts at the
    /// first and ▲ at the last.
    private var crashBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .bold))
            Text(crashLabel)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
            crashArrow("chevron.up", help: "Previous crash") { session.previousCrash() }
            crashArrow("chevron.down", help: "Next crash") { session.nextCrash() }
        }
        .foregroundStyle(LemonadeTheme.colors.content.contentCritical)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Capsule().fill(LemonadeTheme.colors.content.contentCritical.opacity(0.14)))
        .overlay(Capsule().strokeBorder(LemonadeTheme.colors.content.contentCritical.opacity(0.4), lineWidth: 1))
        .accessibilityIdentifier("crashBadge")
    }

    /// "3 crashes" before you start navigating, then "2/3" once you're on one.
    private var crashLabel: String {
        if let c = session.crashCursor { return "\(c + 1)/\(session.crashCount)" }
        return "\(session.crashCount) crash\(session.crashCount == 1 ? "" : "es")"
    }

    private func crashArrow(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var clearMenu: some View {
        Menu {
            Button("Clear view", action: { session.clear() })
            if session.device.platform == .android {
                Button("Clear device buffer", action: { session.clearDeviceBuffer() })
            }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Clear")
        .accessibilityLabel("Clear")
        .accessibilityIdentifier("clearMenu")
    }

    private var transportButton: some View {
        Button(action: { session.toggle() }) {
            Image(systemName: session.isRunning ? "stop.fill" : "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(
                    session.isRunning
                        ? LemonadeTheme.colors.content.contentCritical
                        : LemonadeTheme.colors.content.contentBrand
                )
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                        .fill(LemonadeTheme.colors.background.bgNeutralSubtle)
                )
        }
        .buttonStyle(.plain)
        .help(session.isRunning ? "Stop" : "Start")
        .accessibilityLabel(session.isRunning ? "Stop" : "Start")
        .accessibilityIdentifier("logTransportButton")
    }

    private var followButton: some View {
        Button(action: { session.followTail.toggle() }) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    session.followTail
                        ? LemonadeTheme.colors.content.contentBrand
                        : LemonadeTheme.colors.content.contentSecondary
                )
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                        .fill(session.followTail
                            ? LemonadeTheme.colors.background.bgBrandSubtle
                            : LemonadeTheme.colors.background.bgNeutralSubtle)
                )
        }
        .buttonStyle(.plain)
        .help("Follow tail")
        .accessibilityLabel("Follow tail")
        .accessibilityIdentifier("followButton")
    }

    private var levelChips: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing100) {
            ForEach(LogLevel.allCases, id: \.self) { level in
                LemonadeUi.Chip(
                    label: level.short,
                    selected: session.filter.minLevel == level,
                    onChipClicked: { session.setMinLevel(level) }
                )
                .accessibilityIdentifier("level-\(level.short)")
            }
        }
    }

    private var searchField: some View {
        LemonadeUi.SearchField(
            input: $searchText,
            onInputChanged: { value in debounceSearch(value) },
            placeholder: session.filter.isRegex ? "regex…" : "filter text…",
            onInputClear: { session.setQuery("") }
        )
        .frame(maxWidth: 320)
    }

    private var packageField: some View {
        LemonadeUi.SearchField(
            input: $packageText,
            onInputChanged: { value in debouncePackage(value) },
            placeholder: "package id…",
            onInputClear: { session.setPackage("") }
        )
        .frame(maxWidth: 220)
    }

    private func debounceSearch(_ value: String) {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            session.setQuery(value)
        }
    }

    private func debouncePackage(_ value: String) {
        packageDebounce?.cancel()
        packageDebounce = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            session.setPackage(value.trimmingCharacters(in: .whitespaces))
        }
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.displayName).log"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? session.exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Package / app picker

/// Dropdown of installed apps/packages on the device. Selecting one applies it as
/// the package filter; includes a live search and an "all processes" reset.
private struct PackagePicker: View {
    let session: LogSession
    @Binding var packageText: String
    let onSelect: (String) -> Void

    @State private var show = false
    @State private var apps: [AppEntry] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var query = ""

    var body: some View {
        // Re-fetch when we have nothing to show (first open, or a previous attempt came
        // back empty) so a flaky devicectl gets another shot just by reopening.
        Button(action: { show = true; if !loaded || apps.isEmpty { load() } }) {
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        }
        .buttonStyle(.plain)
        .help("Choose app / package")
        .accessibilityLabel("Choose app or package")
        .accessibilityIdentifier("packagePicker")
        .popover(isPresented: $show, arrowEdge: .bottom) { popover }
    }

    private var filtered: [AppEntry] {
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.id.localizedCaseInsensitiveContains(query)
                || ($0.name ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            TextField("Search apps…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(LemonadeTheme.spaces.spacing200)
                .accessibilityIdentifier("appSearch")

            Rectangle().fill(LemonadeTheme.colors.border.borderNeutralLow).frame(height: 1)

            if loading {
                ProgressView().padding(LemonadeTheme.spaces.spacing400)
                    .frame(maxWidth: .infinity)
            } else if apps.isEmpty {
                VStack(spacing: LemonadeTheme.spaces.spacing200) {
                    LemonadeUi.Text("No apps found on this device.",
                                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                                    color: LemonadeTheme.colors.content.contentTertiary)
                    LemonadeUi.Button(label: "Retry", onClick: { load() },
                                      variant: .neutral, type: .subtle, size: .small)
                        .fixedSize()
                }
                .padding(LemonadeTheme.spaces.spacing400)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        row(title: "All processes", subtitle: nil, isUser: false) { select(nil) }
                        ForEach(filtered) { app in
                            row(title: app.display,
                                subtitle: app.name != nil ? app.id : nil,
                                isUser: app.isUserApp) { select(app) }
                        }
                    }
                }
            }
        }
        .frame(width: 340, height: 380)
    }

    private func row(title: String, subtitle: String?, isUser: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Circle()
                    .fill(isUser ? LemonadeTheme.colors.content.contentBrand : Color.clear)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing300)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appRow")
    }

    private func load() {
        // Show the last-known list instantly (iOS cache); only spin if we have nothing yet.
        if apps.isEmpty { apps = session.cachedApps() }
        loading = apps.isEmpty
        // @MainActor so the @State mutations below never happen off the main thread.
        Task { @MainActor in
            let result = await session.installedApps()
            if !result.isEmpty { apps = result }   // keep the cache shown if a refresh fails
            loaded = !apps.isEmpty                  // stay un-loaded while empty so reopen retries
            loading = false
        }
    }

    private func select(_ app: AppEntry?) {
        // Dismiss the popover first, then apply the filter on the next runloop —
        // mutating ancestor state while the popover tears down can crash on macOS.
        show = false
        // Every platform now scopes by the package / bundle id: Android & simulator
        // resolve it to PIDs; physical iOS launches that bundle under devicectl's console
        // for un-redacted os_log + print(). Empty = "All processes" (whole-device passive).
        let value = app?.id ?? ""
        DispatchQueue.main.async { onSelect(value) }
    }
}

// MARK: - Log list

private extension View {
    /// Liquid Glass capsule on macOS 26+, with a frosted-material fallback.
    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 12, y: 5)
        }
    }
}

/// Monospaced log list backed by an NSTableView (see `LogTableView`) — a fixed-row
/// virtualized list that holds a huge buffer at a flat cost, stays pinned to the tail
/// while following, and keeps your position rock-steady when you scroll up.
private struct LogListView: View {
    let session: LogSession
    var isActive: Bool = true
    @State private var pausedCount = 0   // visible.count when the user paused follow

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Reading these values here is what establishes the @Observable dependency,
            // so the table's updateNSView runs on each flush / filter change / follow toggle.
            LogTableView(session: session, isActive: isActive,
                         revision: session.visible.count, epoch: session.listEpoch,
                         follow: session.followTail, target: session.scrollTarget)
                .background(LemonadeTheme.colors.background.bgDefault)
            if !session.followTail {
                jumpToLatestButton()
                    .padding(20)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: session.followTail)
        .onChange(of: session.followTail) { _, follow in
            if !follow { pausedCount = session.visible.count }
        }
    }

    /// Glassy "jump to latest" pill, shown when the user has scrolled up. Tapping it
    /// resumes following — the table scrolls to the bottom on the next update.
    private func jumpToLatestButton() -> some View {
        let n = max(0, session.visible.count - pausedCount)
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                session.followTail = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down").font(.system(size: 12, weight: .bold))
                if n > 0 {
                    Text(n > 999 ? "999+ new" : "\(n) new").font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .accessibilityIdentifier("jumpToLatest")
    }
}

// MARK: - Status bar

private struct StatusBarView: View {
    let session: LogSession

    var body: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing300) {
            statusDot
            metric("\(session.visible.count) shown")
            metric("\(session.totalCount) total")
            if session.droppedCount > 0 {
                metric("\(session.droppedCount) dropped")
            }
            Spacer()
            metric(session.device.displayModel)
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    private var statusDot: some View {
        Circle()
            .fill(session.isRunning
                ? LemonadeTheme.colors.content.contentPositive
                : LemonadeTheme.colors.content.contentTertiary)
            .frame(width: 8, height: 8)
    }

    private func metric(_ text: String) -> some View {
        LemonadeUi.Text(
            text,
            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
            color: LemonadeTheme.colors.content.contentSecondary,
            maxLines: 1
        )
    }
}
