import SwiftUI
import Lemonade
import AppKit

/// App settings: toolchain paths, history retention, and appearance. Persisted
/// via `UserDefaults` (`@AppStorage`); changes apply immediately.
struct SettingsView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("adbPath") private var adbPath = ""
    @AppStorage("retentionDays") private var retentionDays = 7
    @AppStorage("colorScheme") private var colorScheme = "dark"
    @AppStorage(DockVisibility.defaultsKey) private var showInDock = false
    @State private var exclusions: [LogExcludeRule] = []

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing500) {
            LemonadeUi.Text("Settings", textStyle: LemonadeTypography.shared.headingSmall,
                            color: LemonadeTheme.colors.content.contentPrimary)

            // Scroll the sections so the footer action stays pinned and visible no matter
            // how tall the content grows (long copy, many exclusion rules, …).
            ScrollView {
                VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing500) {
                    section("Android") {
                        LemonadeUi.Text(
                            "adb path",
                            textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                            color: LemonadeTheme.colors.content.contentSecondary
                        )
                        HStack(spacing: LemonadeTheme.spaces.spacing200) {
                            TextField(currentADBPlaceholder, text: $adbPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            LemonadeUi.Button(label: "Browse…", onClick: browseADB,
                                              variant: .neutral, type: .subtle, size: .small)
                        }
                        LemonadeUi.Text(
                            "Leave blank to auto-detect ($ANDROID_HOME, ~/Library/Android/sdk, PATH).",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary
                        )
                    }

                    section("Network inspection") {
                        Toggle(isOn: Binding(get: { model.httpsDecryptionEnabled },
                                             set: { model.httpsDecryptionEnabled = $0 })) {
                            LemonadeUi.Text(
                                "HTTPS decryption (experimental)",
                                textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                                color: LemonadeTheme.colors.content.contentPrimary
                            )
                        }
                        caption(
                            "Off by default. Network inspection uses the in-process Agent — per-app, with " +
                            "call stacks, no certificate needed — which covers most debugging.\n\n" +
                            "Turn this on to also capture whole-device traffic via the companion app and " +
                            "decrypt HTTPS. Limitations: it installs a CA on the device; apps that use " +
                            "certificate pinning (many banking and secure apps) won't be decrypted and may " +
                            "stop working; traffic over QUIC (HTTP/3) can't be decrypted. Experimental and " +
                            "may be unreliable."
                        )
                    }

                    section("History") {
                        Stepper(value: $retentionDays, in: 1...365) {
                            LemonadeUi.Text(
                                "Keep logs for \(retentionDays) day\(retentionDays == 1 ? "" : "s")",
                                textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentPrimary
                            )
                        }
                    }

                    section("Dock & app switcher") {
                        Toggle(isOn: $showInDock) {
                            LemonadeUi.Text(
                                "Show Jaca in the Dock and ⌘-Tab",
                                textStyle: LemonadeTypography.shared.bodySmallSemiBold,
                                color: LemonadeTheme.colors.content.contentPrimary
                            )
                        }
                        caption(
                            "Off by default: Jaca lives in the menu bar, so it has no Dock icon and doesn't " +
                            "appear in the ⌘-Tab switcher. macOS ties the two together — turning this on adds " +
                            "both. The menu-bar icon stays either way."
                        )
                    }

                    section("Appearance") {
                        Picker("Theme", selection: $colorScheme) {
                            Text("System").tag("system")
                            Text("Dark").tag("dark")
                            Text("Light").tag("light")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 280)
                    }

                    section("Excluded log messages") {
                        LemonadeUi.Text(
                            "Lines matching any rule are hidden in every log tab.",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary
                        )
                        ScrollView {
                            VStack(spacing: LemonadeTheme.spaces.spacing100) {
                                ForEach($exclusions) { $rule in
                                    HStack(spacing: LemonadeTheme.spaces.spacing200) {
                                        Picker("", selection: $rule.mode) {
                                            ForEach(LogExcludeRule.Mode.allCases, id: \.self) { mode in
                                                Text(mode.label).tag(mode)
                                            }
                                        }
                                        .labelsHidden()
                                        .frame(width: 130)
                                        TextField("value", text: $rule.value)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 12, design: .monospaced))
                                        Button { exclusions.removeAll { $0.id == rule.id } } label: {
                                            Image(systemName: "trash")
                                                .foregroundStyle(LemonadeTheme.colors.content.contentCritical)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Remove rule")
                                    }
                                }
                                if exclusions.isEmpty {
                                    LemonadeUi.Text("No rules — nothing is excluded.",
                                                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                                    color: LemonadeTheme.colors.content.contentTertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 130)
                        LemonadeUi.Button(label: "Add rule",
                                          onClick: { exclusions.append(LogExcludeRule(value: "", mode: .prefix)) },
                                          variant: .neutral, type: .subtle, size: .small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Footer actions pinned below the scroll, aligned to the content edges,
            // separated from the scrolling sections by a divider.
            VStack(spacing: LemonadeTheme.spaces.spacing400) {
                Divider()
                HStack {
                    LemonadeUi.Button(label: "Done", onClick: { dismiss() },
                                      variant: .neutral, type: .subtle, size: .medium)
                    Spacer()
                    LemonadeUi.Button(label: "Apply & Rescan Devices", onClick: {
                        model.reloadProviders()
                        dismiss()
                    }, variant: .primary, type: .solid, size: .medium)
                }
            }
        }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 560, height: 620)
        .background(LemonadeTheme.colors.background.bgDefault)
        .onAppear { exclusions = LogExclusionStore.shared.rules }
        .onChange(of: exclusions) { _, new in LogExclusionStore.shared.update(new) }
    }

    private var currentADBPlaceholder: String {
        AndroidToolchain.adbURL()?.path ?? "adb not found"
    }

    /// Tertiary explainer text under a section's control, wrapping over the full width.
    private func caption(_ text: String) -> some View {
        LemonadeUi.Text(text,
                        textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                        color: LemonadeTheme.colors.content.contentTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Text(title.uppercased(),
                            textStyle: LemonadeTypography.shared.bodyXSmallOverline,
                            color: LemonadeTheme.colors.content.contentTertiary)
            content()
        }
    }

    private func browseADB() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            adbPath = url.path
        }
    }
}
