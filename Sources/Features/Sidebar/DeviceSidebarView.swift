import SwiftUI
import Lemonade
import AppKit

/// Live device list. Clicking a ready device opens a small menu to start a new
/// logcat tab or a network-capture tab; each pick opens an independent tab.
struct DeviceSidebarView: View {
    @Bindable var model: AppModel
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showConnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
            HStack {
                LemonadeUi.Text(
                    "Devices",
                    textStyle: LemonadeTypography.shared.headingXSmall,
                    color: model.mode == .devices
                        ? LemonadeTheme.colors.content.contentPrimary
                        : LemonadeTheme.colors.content.contentSecondary
                )
                Spacer()
                // Companion onboarding only exists when the experimental HTTPS-decryption
                // feature is on; otherwise inspection is Agent-only and there's nothing to pair.
                if model.httpsDecryptionEnabled {
                    Button(action: { showConnect = true }) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Connect a device (QR / USB)")
                    .accessibilityIdentifier("connectDeviceButton")
                }
                LemonadeUi.IconButton(
                    icon: .clockArrowUp, contentDescription: "History",
                    onClick: { showHistory = true }, size: .small
                )
                .accessibilityIdentifier("historyButton")
                Button(action: { showSettings = true }) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityIdentifier("settingsButton")
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
            .background(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(model.mode == .devices ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { model.mode = .devices }

            if model.adbURL == nil {
                adbMissingNotice
            }

            if model.httpsDecryptionEnabled && model.companions.networkBlocked {
                localNetworkNotice
            }

            if model.devices.isEmpty {
                emptyState
                macSection
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
                        ForEach(platforms, id: \.self) { platform in
                            deviceSection(platform.displayName.uppercased(),
                                          model.devices.filter { $0.platform == platform && !$0.isCompanion })
                        }
                        // Devices reachable only over the companion link (no USB/ADB).
                        deviceSection("COMPANION", model.devices.filter { $0.isCompanion })
                        macSection
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(LemonadeTheme.spaces.spacing300)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LemonadeTheme.colors.background.bgElevated)
        .sheet(isPresented: $showHistory) {
            HistoryView(model: model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showConnect) {
            CompanionSetupSheet(model: model.companionSetup)
        }
    }

    private var platforms: [DevicePlatform] {
        var seen: [DevicePlatform] = []
        for device in model.devices where !device.isCompanion && !seen.contains(device.platform) {
            seen.append(device.platform)
        }
        return seen
    }

    /// This Mac, always listed: its Chrome window is captured whatever devices are connected.
    private var macSection: some View {
        deviceSection(DevicePlatform.mac.displayName.uppercased(), [Device.thisMac])
    }

    /// A titled group of device rows (a platform, or the companion-only section).
    @ViewBuilder
    private func deviceSection(_ title: String, _ devices: [Device]) -> some View {
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
                LemonadeUi.Text(
                    title,
                    textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                    color: LemonadeTheme.colors.content.contentTertiary
                )
                ForEach(devices) { device in
                    DeviceRow(
                        device: device,
                        onStart: { model.startSession(for: device) },
                        onInspectNetwork: { model.startNetworkSession(for: device, autoStart: false) },
                        onBrowseDatabase: { model.startDatabaseSession(for: device) },
                        onStartCompanion: { model.startNetworkSession(for: device, autoStart: true) },
                        onUpdate: { showConnect = true },
                        updateOverUSB: { await model.updateCompanionOverUSB(device) },
                        checkProxy: { await model.strandedProxy(for: device) },
                        revertProxy: { await model.revertDeviceProxy(device) }
                    )
                }
            }
        }
    }

    private var adbMissingNotice: some View {
        LemonadeUi.Notice(
            content: "adb not found. Set its path in Settings or install Android platform-tools.",
            voice: .critical
        )
    }

    /// macOS blocks the in-app mDNS browse until Local Network permission is granted, and there's
    /// no API to request it on demand — so guide the user straight to the setting.
    private var localNetworkNotice: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
            LemonadeUi.Notice(
                content: "Allow Jaca under Local Network so it can find companion devices on your Wi-Fi.",
                voice: .warning
            )
            LemonadeUi.Button(label: "Open Local Network Settings",
                              onClick: { Self.openLocalNetworkSettings() },
                              variant: .neutral, type: .subtle, size: .small)
        }
    }

    private static func openLocalNetworkSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
    }

    private var emptyState: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Icon(icon: .smartphone, contentDescription: nil, size: .large,
                            tint: LemonadeTheme.colors.content.contentTertiary)
            LemonadeUi.Text(
                "No devices connected",
                textStyle: LemonadeTypography.shared.bodySmallRegular,
                textAlign: .center,
                color: LemonadeTheme.colors.content.contentSecondary
            )
            LemonadeUi.Text(
                "Connect a device or start an emulator.",
                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                textAlign: .center,
                color: LemonadeTheme.colors.content.contentTertiary
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, LemonadeTheme.spaces.spacing600)
    }
}

private struct DeviceRow: View {
    let device: Device
    let onStart: () -> Void
    let onInspectNetwork: () -> Void
    /// Open a Database tab (browse an app's local SQLite DB).
    var onBrowseDatabase: () -> Void = {}
    /// Start (and auto-run) companion network capture — the primary action for companion devices.
    let onStartCompanion: () -> Void
    /// Fallback for a Wi-Fi / companion-only device: open the QR connect sheet to reinstall an
    /// out-of-date companion app.
    let onUpdate: () -> Void
    /// One-click update over USB for an adb-connected device (no QR step). Returns the outcome
    /// so the row can fall back to the sheet when there's no USB path.
    let updateOverUSB: () async -> AppModel.CompanionUpdateOutcome
    /// Returns the device's stranded Jaca proxy, or nil: a proxy at this Mac, or a device-proxy
    /// ledger value that no running capture holds (`AppModel.strandedProxy`).
    let checkProxy: () async -> String?
    /// Reverts the device's HTTP proxy: restores what the device had before Jaca for a ledger
    /// value, else clears it.
    let revertProxy: () async -> Void
    @State private var hovering = false
    @State private var stranded: String?
    @State private var reverting = false
    @State private var showOptions = false
    @State private var isUpdating = false
    @State private var updateError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
            deviceButton
            if let proxy = stranded { strandedBanner(proxy).transition(.opacity) }
            if let err = updateError { updateErrorBanner(err) }
        }
        .task(id: device.state) {
            stranded = device.state.isReady ? await checkProxy() : nil
        }
        .animation(.easeInOut(duration: 0.2), value: isUpdating)
        .animation(.easeInOut(duration: 0.2), value: updateError)
        .animation(.easeInOut(duration: 0.2), value: stranded)
    }

    /// Update an out-of-date companion. For an adb device this installs over USB in place (no
    /// QR step); for a Wi-Fi / companion-only device it falls back to the connect sheet.
    private func triggerUpdate() {
        Task {
            updateError = nil
            isUpdating = true
            let outcome = await updateOverUSB()
            isUpdating = false
            switch outcome {
            case .noUSBPath: onUpdate()                 // QR/connect sheet fallback
            case .success: break                         // chip clears when the new build reports its commit
            case .failed(let msg): updateError = msg
            }
        }
    }

    /// A companion device (network only) or a ready adb/ios device can be acted on:
    /// companions open Network inspection directly, adb/ios open the logcat/network menu.
    private var actionable: Bool { networkOnly || device.state.isReady }

    /// A companion-only device or this Mac: network is all it has, so a click starts capture.
    private var networkOnly: Bool { device.isCompanion || device.platform == .mac }

    private var subtitle: String {
        if device.platform == .mac { return "Chrome (network only)" }
        return device.isCompanion ? "Companion (network only)" : device.id
    }

    private var deviceButton: some View {
        Button(action: {
            if networkOnly { onStartCompanion() }
            else if device.state.isReady { showOptions = true }
        }) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Icon(
                    icon: device.platform == .mac ? .laptop : .smartphone, contentDescription: nil, size: .medium,
                    tint: LemonadeTheme.colors.content.contentSecondary
                )
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        LemonadeUi.Text(
                            device.displayModel,
                            textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                            color: LemonadeTheme.colors.content.contentPrimary,
                            maxLines: 1
                        )
                        if device.companionID != nil { companionChip }
                        if device.companionUpdateAvailable { updateChip }
                    }
                    LemonadeUi.Text(
                        subtitle,
                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentTertiary,
                        maxLines: 1
                    )
                }
                Spacer(minLength: 0)
                if actionable {
                    // Companion: direct play (network only). adb/ios: chevron opens the logcat/network menu.
                    Image(systemName: networkOnly ? "play.fill" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                        .rotationEffect(.degrees(showOptions ? 180 : 0))
                        .opacity(hovering || showOptions ? 1 : 0.35)
                        .animation(.easeInOut(duration: 0.15), value: showOptions)
                } else {
                    stateBadge
                }
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing200)
            .background(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill((hovering || showOptions) && actionable
                        ? LemonadeTheme.colors.interaction.bgSubtleInteractive
                        : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!actionable)
        .accessibilityIdentifier("deviceRow")
        .onHover { hovering = $0 }
        .help(device.platform == .mac ? "Inspect network (Chrome)"
              : device.isCompanion ? "Inspect network (companion)"
              : (device.state.isReady ? "Logcat or network capture" : device.state.label))
        .popover(isPresented: $showOptions, arrowEdge: .bottom) {
            inspectMenu
        }
        .contextMenu {
            // Right-click path for the companion update — reachable even on companion-only
            // devices, which single-click straight into capture and never open the popover.
            if device.companionUpdateAvailable {
                Button("Update Companion App…") { triggerUpdate() }
            }
        }
    }

    /// Pops up on a single click of a ready adb/ios device: pick logcat or network capture.
    private var inspectMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            OptionMenuRow(icon: "play.fill", title: "Start Logcat") {
                showOptions = false
                onStart()
            }
            OptionMenuRow(icon: "network", title: "Inspect Network") {
                showOptions = false
                onInspectNetwork()
            }
            OptionMenuRow(icon: "cylinder.split.1x2", title: "Browse Database") {
                showOptions = false
                onBrowseDatabase()
            }
            if device.companionUpdateAvailable {
                Divider()
                Button("Update Companion App…") { showOptions = false; triggerUpdate() }
            }
        }
        .padding(LemonadeTheme.spaces.spacing100)
        .frame(minWidth: 196)
    }

    /// Green when the companion stream is connected, red (caution) when it isn't.
    private var companionChip: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(device.companionConnected
                    ? LemonadeTheme.colors.content.contentPositive
                    : LemonadeTheme.colors.content.contentCritical)
                .frame(width: 6, height: 6)
            Text("companion")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(LemonadeTheme.colors.background.bgNeutralSubtle))
    }

    /// Shown when the device's companion app is older than the APK Jaca bundles. Spins while a
    /// USB update is in flight; clears on its own when the refreshed build reports its commit.
    private var updateChip: some View {
        HStack(spacing: 3) {
            if isUpdating {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 9, height: 9)
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(isUpdating ? "updating…" : "update")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(LemonadeTheme.colors.content.contentCaution)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        .help(isUpdating ? "Updating the companion app over USB…"
                         : "The companion app is out of date. Right-click → Update Companion App (installs over USB when connected).")
    }

    /// Inline failure feedback for a USB update (tap to dismiss).
    private func updateErrorBanner(_ msg: String) -> some View {
        LemonadeUi.Text(msg, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentCritical, maxLines: 3)
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .contentShape(Rectangle())
            .onTapGesture { updateError = nil }
    }

    /// Shown when this device still has a proxy Jaca set but a teardown couldn't
    /// revert (e.g. the app or jacad was force-killed). One click reverts it.
    private func strandedBanner(_ proxy: String) -> some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(LemonadeTheme.colors.content.contentCaution)
            VStack(alignment: .leading, spacing: 1) {
                LemonadeUi.Text("Proxy left set by Jaca",
                                textStyle: LemonadeTypography.shared.bodyXSmallSemiBold,
                                color: LemonadeTheme.colors.content.contentPrimary, maxLines: 1)
                LemonadeUi.Text(proxy,
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary, maxLines: 1)
            }
            Spacer(minLength: 6)
            if reverting {
                ProgressView().controlSize(.small)
            } else {
                LemonadeUi.Button(label: "Revert", onClick: { revert() },
                                  variant: .neutral, type: .subtle, size: .small)
            }
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing200)
        .padding(.vertical, LemonadeTheme.spaces.spacing100)
        .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
            .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        .accessibilityIdentifier("strandedProxyBanner")
    }

    private func revert() {
        reverting = true
        Task {
            await revertProxy()
            stranded = await checkProxy()   // clears the banner once it's actually gone
            reverting = false
        }
    }

    private var stateBadge: some View {
        LemonadeUi.Text(
            device.state.label,
            textStyle: LemonadeTypography.shared.bodyXSmallSemiBold,
            color: device.state == .unauthorized
                ? LemonadeTheme.colors.content.contentCaution
                : LemonadeTheme.colors.content.contentTertiary,
            maxLines: 1
        )
    }
}

/// A single row inside the device inspect popover (logcat / network).
private struct OptionMenuRow: View {
    let icon: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .frame(width: 18)
                LemonadeUi.Text(
                    title,
                    textStyle: LemonadeTypography.shared.bodySmallRegular,
                    color: LemonadeTheme.colors.content.contentPrimary,
                    maxLines: 1
                )
                Spacer(minLength: 12)
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing200)
            .padding(.vertical, LemonadeTheme.spaces.spacing100)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(hovering ? LemonadeTheme.colors.interaction.bgSubtleInteractive : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .accessibilityIdentifier(title)
    }
}
