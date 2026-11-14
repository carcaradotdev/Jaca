import SwiftUI
import Lemonade
import AppKit

/// Top-level shell: device sidebar on the left, the active session (tab) on the
/// right with a tab strip above it.
struct RootView: View {
    @State private var model = AppModel()
    @State private var showCopyFormat = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            detail
        }
        .sheet(isPresented: $showCopyFormat) { LogCopyFormatSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .openLogCopyFormat)) { _ in
            showCopyFormat = true
        }
        .task {
            model.startDiscovery()
            UpdateModel.shared.start()
            // Bring the window frontmost so it becomes key on launch.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.persistTabs() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openProjects)) { _ in
            model.mode = .projects
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            // Section headers (styled like the Devices header) that navigate the main
            // area when tapped. The Devices header + device list stay below, unchanged.
            ProjectsSidebarHeader(model: model)
            GradleSidebarHeader(model: model)
            XcodeSidebarHeader(model: model)
            CloudLoggingSidebarSection(model: model)
            Divider()
            DeviceSidebarView(model: model)
            UpdateBanner()
        }
        .background(LemonadeTheme.colors.background.bgElevated)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if model.mode == .projects {
            ProjectsAreaView(model: model.projects)
        } else if model.mode == .gradle {
            GradleDaemonsView(model: model.gradle)
        } else if model.mode == .xcode {
            XcodeAreaView(model: model.xcode)
        } else if model.mode == .cloudLogging {
            CloudLoggingHomeView(model: model)
        } else {
            devicesDetail
        }
    }

    @ViewBuilder
    private var devicesDetail: some View {
        if model.sessions.isEmpty {
            EmptySessionView()
        } else {
            VStack(spacing: 0) {
                TabStripView(model: model)
                Rectangle()
                    .fill(LemonadeTheme.colors.border.borderNeutralLow)
                    .frame(height: 1)
                // Keep every tab's view alive and just show the selected one, so
                // switching tabs preserves scroll position / selection / state instead
                // of recreating the view (which caused a full redraw + scroll jump).
                ZStack {
                    ForEach(model.sessions, id: \.id) { session in
                        let active = session.id == model.selectedSessionID
                        sessionView(for: session, isActive: active)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .zIndex(active ? 1 : 0)
                    }
                }
            }
            .background(LemonadeTheme.colors.background.bgDefault)
        }
    }

    @ViewBuilder
    private func sessionView(for session: any WorkspaceTab, isActive: Bool) -> some View {
        if let log = session as? LogSession {
            LogSessionView(session: log, isActive: isActive)
        } else if let net = session as? NetworkSession {
            NetworkSessionView(session: net, inspectionMode: $model.networkInspectionMode)
        } else if let db = session as? DatabaseSession {
            DatabaseSessionView(session: db)
        } else if let cloud = session as? CloudLogSession {
            CloudLogSessionView(session: cloud, model: model, isActive: isActive)
        }
    }
}

struct EmptySessionView: View {
    var body: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing300) {
            LemonadeUi.Icon(
                icon: .bug, contentDescription: nil, size: .large,
                tint: LemonadeTheme.colors.content.contentSecondary
            )
            LemonadeUi.Text(
                "Jaca",
                textStyle: LemonadeTypography.shared.headingSmall,
                color: LemonadeTheme.colors.content.contentPrimary
            )
            LemonadeUi.Text(
                "Select a device on the left to start a logcat session.",
                textStyle: LemonadeTypography.shared.bodyMediumRegular,
                textAlign: .center,
                color: LemonadeTheme.colors.content.contentSecondary
            )
        }
        .padding(LemonadeTheme.spaces.spacing800)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LemonadeTheme.colors.background.bgDefault)
        .accessibilityIdentifier("emptyState")
    }
}
