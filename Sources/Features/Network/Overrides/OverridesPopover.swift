import SwiftUI
import AppKit
import Lemonade

/// The override library. A browsing surface, so a popover (like `NetworkAppPicker`), not a sheet.
///
/// Precedence is list order — a firewall table, not a specificity score — so the winner is always
/// visible and "move this rule up" is a one-click fix.
struct OverridesPopover: View {
    @Bindable var session: NetworkSession
    @Bindable var overrides: OverridesModel

    @State private var editing: OverrideDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)

            if overrides.rules.isEmpty {
                emptyState
            } else {
                rulesList
            }

            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
            footer
        }
        .frame(width: 380)
        .background(LemonadeTheme.colors.background.bgDefault)
        .task { await session.refreshDeviceProxyState() }
        .sheet(item: $editing) { draft in
            OverrideEditorSheet(
                rule: draft.rule,
                session: session,
                overrides: overrides,
                isNew: draft.isNew,
                // `save` adds or updates: calling `update` here discarded every new rule.
                onSave: { saved in
                    withAnimation(.easeInOut(duration: 0.28)) { overrides.save(saved) }
                }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Text("Overrides", textStyle: LemonadeTypography.shared.headingXSmall,
                            color: LemonadeTheme.colors.content.contentPrimary)
            Spacer()
            // The master switch: "let me see the real thing for a second".
            LemonadeUi.Switch(checked: overrides.masterEnabled) { newValue in
                withAnimation(.easeInOut(duration: 0.2)) { overrides.masterEnabled = newValue }
            }
            .help(overrides.masterEnabled
                  ? "Pause all overrides — rules stay saved"
                  : "Resume overrides")
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
    }

    // MARK: - List

    private var rulesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(overrides.rules.enumerated()), id: \.element.id) { index, rule in
                    OverrideRuleRow(
                        rule: rule,
                        hitCount: overrides.hitCount(for: rule.id),
                        diagnostic: overrides.diagnostic(for: rule.id),
                        blockedReason: blockedReason(for: rule),
                        masterEnabled: overrides.masterEnabled,
                        onToggle: { enabled in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                overrides.setEnabled(enabled, for: rule.id)
                            }
                        },
                        onEdit: { editing = .existing(rule) },
                        onMoveUp: index > 0 ? {
                            withAnimation(.easeInOut(duration: 0.2)) { overrides.move(rule.id, by: -1) }
                        } : nil,
                        onMoveDown: index < overrides.rules.count - 1 ? {
                            withAnimation(.easeInOut(duration: 0.2)) { overrides.move(rule.id, by: 1) }
                        } : nil,
                        onDuplicate: { overrides.duplicate(rule.id) },
                        onDelete: {
                            withAnimation(.easeInOut(duration: 0.28)) { overrides.remove(rule.id) }
                        }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))

                    if rule.id != overrides.rules.last?.id {
                        Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
                    }
                }
            }
        }
        .frame(maxHeight: 320)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: LemonadeTheme.spaces.spacing200) {
            Image(systemName: "bolt")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
            LemonadeUi.Text("No response overrides",
                            textStyle: LemonadeTypography.shared.bodySmallMedium,
                            color: LemonadeTheme.colors.content.contentPrimary)
            LemonadeUi.Text("Right-click any captured request to override its response, or create one from scratch.",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            textAlign: .center,
                            color: LemonadeTheme.colors.content.contentSecondary)
            LemonadeUi.Text("Overrides replace the response your app receives.",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            textAlign: .center,
                            color: LemonadeTheme.colors.content.contentTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LemonadeTheme.spaces.spacing400)
        .padding(.vertical, LemonadeTheme.spaces.spacing500)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.Button(label: "New override",
                              onClick: { editing = .new(OverrideEditorSheet.blankRule(seedHost: seedHost)) },
                              leadingIcon: .plus, variant: .neutral, type: .subtle, size: .small)

            // The visible teardown + blast-radius contract: exactly what is running, and where.
            statusLine
                .animation(.easeInOut(duration: 0.2), value: armingState)

            deviceNetworkSection

            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                Button("Show log") {
                    NSWorkspace.shared.activateFileViewerSelecting([JacaLog.fileURL])
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
                .help("Opens ~/.jaca/logs/jaca.log — what Jaca did, and why a rule did or didn't fire")

                if let last = overrides.lastActivity {
                    Text(last)
                        .font(LogLevelStyle.mono(9))
                        .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                        .lineLimit(1).truncationMode(.head)
                        .help(last)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: overrides.lastActivity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch armingState {
        case .active(let port, let hosts):
            let hostText = hosts.isEmpty
                ? "No hosts routed"
                : "Diverting \(hosts.count) host\(hosts.count == 1 ? "" : "s"): \(hosts.sorted().joined(separator: ", "))"
            // Both halves are transport-dependent: only Android reaches this port through
            // `adb reverse`, and only Android has a tunnel to promise the removal of.
            LemonadeUi.Text("\(hostText) · \(transport.portLabel(port: port))",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary, maxLines: 2)
                .help(transport.divertScopeHelp)
        case .failed(let detail):
            VStack(alignment: .leading, spacing: 2) {
                LemonadeUi.Text("Overrides inactive",
                                textStyle: LemonadeTypography.shared.bodyXSmallMedium,
                                color: LemonadeTheme.colors.content.contentCritical)
                Text(detail)
                    .font(LogLevelStyle.mono(10))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .textSelection(.enabled)      // it's a dev tool: let them copy the raw error
                    .lineLimit(3)
            }
        // Same sentence as the row badge and toolbar — one state, one wording.
        case .waitingForAgent, .agentTooOld, .waitingForApp, .detached:
            LemonadeUi.Text(armingState.blockedMessage ?? "",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentCaution, maxLines: 2)
        case .idle:
            LemonadeUi.Text(idleMessage,
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary, maxLines: 2)
        }
    }

    private var idleMessage: String {
        if !FeatureFlags.responseOverridesEnabled {
            return "Turn on Response overrides in Settings to apply these rules."
        }
        if session.captureMode != .agent {
            return "Overrides apply to in-process agent capture. Other transports will follow."
        }
        return overrides.rules.isEmpty ? "" : "Start capture to apply these overrides."
    }

    /// Recovery for a device left behind by a crashed capture session. Clearing `http_proxy`
    /// isn't enough — Android also keeps `global_http_proxy_*` per network, and while those
    /// survive the device sits unvalidated ("connected, no internet").
    @ViewBuilder
    private var deviceNetworkSection: some View {
        if session.isADBDevice {
            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                VStack(alignment: .leading, spacing: 1) {
                    LemonadeUi.Text("Device proxy",
                                    textStyle: LemonadeTypography.shared.bodyXSmallMedium,
                                    color: LemonadeTheme.colors.content.contentSecondary)
                    LemonadeUi.Text(session.deviceProxyLingers
                                    ? "A proxy is still set on this device — it may have no internet."
                                    : "Not set.",
                                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: session.deviceProxyLingers
                                        ? LemonadeTheme.colors.content.contentCaution
                                        : LemonadeTheme.colors.content.contentTertiary,
                                    maxLines: 2)
                }
                Spacer()
                LemonadeUi.Button(
                    label: session.isRevertingDeviceProxy ? "Reverting…" : "Revert",
                    onClick: { Task { await session.revertDeviceProxy() } },
                    variant: .neutral, type: .subtle, size: .small,
                    enabled: !session.isRevertingDeviceProxy)
                .help("Clears every proxy setting on this device and re-validates its network.")
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing300)
            .padding(.vertical, LemonadeTheme.spaces.spacing200)
            .animation(.easeInOut(duration: 0.2), value: session.deviceProxyLingers)
            .animation(.easeInOut(duration: 0.2), value: session.isRevertingDeviceProxy)
        }
    }

    /// One reader for the arming state — see `NetworkSession.armingState`.
    private var armingState: InterceptArmingState { session.armingState }

    /// The interception point this tab captures through; keys every transport-dependent
    /// sentence here.
    private var transport: InterceptTransportID { session.interceptTransport }

    /// Seeds a from-scratch rule with the host the user is already looking at.
    private var seedHost: String? {
        session.selectedTransaction?.host ?? session.transactions.last?.host
    }

    /// Why this rule can't run on the tab's current transport, using the same clamp as runtime.
    private func blockedReason(for rule: OverrideRule) -> String? {
        guard rule.enabled, overrides.masterEnabled else { return nil }
        // Nothing is running, so there is no transport to be incompatible with.
        guard session.hasRunningSource else { return nil }
        let compiled = CompiledRule(rule: rule, program: nil, regex: nil)
        let (_, skip) = OverrideMatching.decide(compiled,
                                                transport: session.interceptTransport,
                                                capabilities: session.activeInterceptCapabilities,
                                                masterEnabled: true)
        return skip?.message
    }
}

// MARK: - Row

/// One rule. **No whole-row tap gesture**: the name/pattern block is its own button and the
/// switch is a sibling, because a row-level `onTapGesture` fights the switch for the click.
private struct OverrideRuleRow: View {
    let rule: OverrideRule
    let hitCount: Int
    let diagnostic: String?
    let blockedReason: String?
    let masterEnabled: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(rule.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                            .lineLimit(1)
                        if diagnostic != nil {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(LemonadeTheme.colors.content.contentCaution)
                        }
                    }
                    Text(rule.matcher.pattern.isEmpty ? "No pattern" : rule.matcher.pattern)
                        .font(LogLevelStyle.mono(10))
                        .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(diagnostic ?? "Edit this override")

            if let blockedReason {
                LemonadeUi.Tag(label: "not here", voice: .warning)
                    .help(blockedReason)
            } else if hitCount > 0 {
                Text("\(hitCount)×")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                    .contentTransition(.numericText())
                    .help("Applied \(hitCount) time\(hitCount == 1 ? "" : "s") this session")
            }

            LemonadeUi.Switch(checked: rule.enabled, onCheckedChange: onToggle, enabled: masterEnabled)
        }
        .padding(.horizontal, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
        .opacity(rule.enabled && masterEnabled ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.2), value: rule.enabled)
        .animation(.easeInOut(duration: 0.2), value: masterEnabled)
        .contextMenu {
            Button("Edit override…", action: onEdit)
            if let onMoveUp { Button("Move up", action: onMoveUp) }
            if let onMoveDown { Button("Move down", action: onMoveDown) }
            Divider()
            Button("Duplicate", action: onDuplicate)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
