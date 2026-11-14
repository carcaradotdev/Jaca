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
    /// Asks the network tab to open the editor. The popover doesn't present it itself: a sheet
    /// attached to a popover's window doesn't block the main window, and clicking the main window
    /// closes the popover out from under the sheet — after which dismissing the editor left its
    /// dimming layer stuck over the window.
    let onEdit: (OverrideDraft) -> Void

    /// The group whose name is in a text field, and that text.
    @State private var renamingGroupID: UUID?
    @State private var groupName = ""
    @FocusState private var groupNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)

            Group {
                if isEmpty {
                    emptyState
                } else {
                    rulesList
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isEmpty)

            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
            footer
        }
        .frame(width: 380)
        .background(LemonadeTheme.colors.background.bgDefault)
        .task { await session.refreshDeviceProxyState() }
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

    private var isEmpty: Bool { overrides.rules.isEmpty && overrides.groups.isEmpty }

    /// The groups, each with its rules under it while open, then the rules in no group.
    /// Precedence is this order, top to bottom.
    private var rulesList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(overrides.sections, id: \.group?.id) { section in
                    if let group = section.group {
                        groupRow(group, ruleCount: section.rules.count)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        if overrides.expandedGroups.contains(group.id) {
                            if section.rules.isEmpty {
                                emptyGroupRow
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            ruleRows(section.rules, in: group)
                        }
                    } else {
                        ruleRows(section.rules, in: nil)
                    }
                }
            }
            // In daemon mode the edit lands later, from jacad's state, outside the button's
            // `withAnimation`: animate list changes whenever they arrive.
            .animation(.easeInOut(duration: 0.2), value: overrides.rules)
            .animation(.easeInOut(duration: 0.2), value: overrides.groups)
            .animation(.easeInOut(duration: 0.2), value: overrides.expandedGroups)
        }
        .frame(maxHeight: 320)
    }

    private var divider: some View {
        Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
    }

    @ViewBuilder
    private func ruleRows(_ rules: [OverrideRule], in group: OverrideGroup?) -> some View {
        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
            // Every row but the first in the list has a divider above it.
            if group != nil || index > 0 || !overrides.groups.isEmpty { divider }
            OverrideRuleRow(
                rule: rule,
                active: overrides.isActive(rule),
                indented: group != nil,
                hitCount: overrides.hitCount(for: rule.id),
                diagnostic: overrides.diagnostic(for: rule.id),
                blockedReason: blockedReason(for: rule),
                masterEnabled: overrides.masterEnabled,
                groups: overrides.groups,
                onToggle: { enabled in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        overrides.setEnabled(enabled, for: rule.id)
                    }
                },
                onEdit: { onEdit(.existing(rule)) },
                // A rule moves inside its own group; "Move to group" takes it to another.
                onMoveUp: index > 0 ? {
                    withAnimation(.easeInOut(duration: 0.2)) { overrides.move(rule.id, by: -1) }
                } : nil,
                onMoveDown: index < rules.count - 1 ? {
                    withAnimation(.easeInOut(duration: 0.2)) { overrides.move(rule.id, by: 1) }
                } : nil,
                onMoveToGroup: { groupID in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let groupID { overrides.expandedGroups.insert(groupID) }
                        overrides.setGroup(groupID, for: rule.id)
                    }
                },
                onDuplicate: { overrides.duplicate(rule.id) },
                onDelete: {
                    withAnimation(.easeInOut(duration: 0.28)) { overrides.remove(rule.id) }
                }
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Groups

    /// One group. Like a rule row, **no whole-row tap gesture**: the chevron and name are one
    /// button, which opens or closes the group, and the switch is a sibling.
    private func groupRow(_ group: OverrideGroup, ruleCount: Int) -> some View {
        let expanded = overrides.expandedGroups.contains(group.id)
        let index = overrides.groups.firstIndex { $0.id == group.id } ?? 0
        return VStack(spacing: 0) {
            if index > 0 { divider }
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                if renamingGroupID == group.id {
                    // Outside the button, so a click in the field doesn't close the group.
                    HStack(spacing: 6) {
                        groupIcons(expanded: expanded)
                        TextField("Group name", text: $groupName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .focused($groupNameFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { renamingGroupID = nil }
                            .onChange(of: groupNameFocused) { _, focused in
                                if !focused { commitRename() }
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { toggleExpanded(group.id) }
                    } label: {
                        HStack(spacing: 6) {
                            groupIcons(expanded: expanded)
                            Text(group.name.isEmpty ? "Untitled group" : group.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                                .lineLimit(1)
                            Text("\(ruleCount)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                                .contentTransition(.numericText())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide the overrides in this group" : "Show the overrides in this group")
                }

                LemonadeUi.Switch(checked: group.enabled,
                                  onCheckedChange: { enabled in
                                      withAnimation(.easeInOut(duration: 0.2)) {
                                          overrides.setEnabled(enabled, forGroup: group.id)
                                      }
                                  },
                                  enabled: overrides.masterEnabled)
                    .help(group.enabled
                          ? "Turn off every override in this group"
                          : "Turn on this group's overrides")
            }
            .padding(.horizontal, LemonadeTheme.spaces.spacing300)
            .padding(.vertical, LemonadeTheme.spaces.spacing200)
            .opacity(group.enabled && overrides.masterEnabled ? 1 : 0.45)
            .animation(.easeInOut(duration: 0.2), value: expanded)
            .animation(.easeInOut(duration: 0.2), value: group.enabled)
            .contextMenu {
                Button("Rename group…") { startRename(group) }
                Button("New override in group") {
                    var rule = OverrideEditorSheet.blankRule(seedHost: seedHost)
                    rule.groupID = group.id
                    overrides.expandedGroups.insert(group.id)
                    onEdit(.new(rule))
                }
                if index > 0 {
                    Button("Move up") {
                        withAnimation(.easeInOut(duration: 0.2)) { overrides.moveGroup(group.id, by: -1) }
                    }
                }
                if index < overrides.groups.count - 1 {
                    Button("Move down") {
                        withAnimation(.easeInOut(duration: 0.2)) { overrides.moveGroup(group.id, by: 1) }
                    }
                }
                Divider()
                // Its overrides stay, in no group.
                Button("Delete group", role: .destructive) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        overrides.expandedGroups.remove(group.id)
                        overrides.removeGroup(group.id)
                    }
                }
            }
        }
    }

    private func groupIcons(expanded: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 10)
            Image(systemName: expanded ? "folder.fill" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
        }
    }

    private var emptyGroupRow: some View {
        VStack(spacing: 0) {
            divider
            LemonadeUi.Text("No overrides yet. Right-click an override and choose Move to group.",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary, maxLines: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, LemonadeTheme.spaces.spacing300 + OverrideRuleRow.indent)
                .padding(.trailing, LemonadeTheme.spaces.spacing300)
                .padding(.vertical, LemonadeTheme.spaces.spacing200)
        }
    }

    private func toggleExpanded(_ id: UUID) {
        if overrides.expandedGroups.contains(id) {
            overrides.expandedGroups.remove(id)
        } else {
            overrides.expandedGroups.insert(id)
        }
    }

    private func newGroup() {
        let group = OverrideGroup(name: "Untitled group")
        withAnimation(.easeInOut(duration: 0.2)) {
            overrides.expandedGroups.insert(group.id)
            overrides.saveGroup(group)
        }
        startRename(group)
    }

    private func startRename(_ group: OverrideGroup) {
        groupName = group.name
        renamingGroupID = group.id
        // After the field is in the view.
        DispatchQueue.main.async { groupNameFocused = true }
    }

    /// Saves the typed name. A blank name keeps the old one.
    private func commitRename() {
        guard renamingGroupID != nil else { return }
        defer { renamingGroupID = nil }
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = renamingGroupID, !name.isEmpty,
              var group = overrides.groups.first(where: { $0.id == id }), group.name != name else { return }
        group.name = name
        overrides.saveGroup(group)
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
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Button(label: "New override",
                                  onClick: { onEdit(.new(OverrideEditorSheet.blankRule(seedHost: seedHost))) },
                                  leadingIcon: .plus, variant: .neutral, type: .subtle, size: .small)
                LemonadeUi.Button(label: "New group", onClick: newGroup,
                                  leadingIcon: .plus, variant: .neutral, type: .subtle, size: .small)
            }

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
                .help(transport.routingScopeHelp)
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
        Self.idleMessage(captureMode: session.captureMode, hasRules: !overrides.rules.isEmpty)
    }

    /// The idle line. Overrides run in both inspection modes, so only the companion stream,
    /// which applies no rule, gets the agent-only line.
    static func idleMessage(captureMode: CaptureMode, hasRules: Bool) -> String {
        if captureMode == .companion {
            return "Overrides apply to in-process agent capture. Other transports will follow."
        }
        return hasRules ? "Start capture to apply these overrides." : ""
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
        guard overrides.isActive(rule), overrides.masterEnabled else { return nil }
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
    /// How far a rule in a group sits in from the group's row.
    static let indent: CGFloat = 16

    let rule: OverrideRule
    /// On, and so is its group.
    let active: Bool
    let indented: Bool
    let hitCount: Int
    let diagnostic: String?
    let blockedReason: String?
    let masterEnabled: Bool
    let groups: [OverrideGroup]
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    /// nil takes the rule out of its group.
    let onMoveToGroup: (UUID?) -> Void
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
        .padding(.leading, LemonadeTheme.spaces.spacing300 + (indented ? Self.indent : 0))
        .padding(.trailing, LemonadeTheme.spaces.spacing300)
        .padding(.vertical, LemonadeTheme.spaces.spacing200)
        .opacity(active && masterEnabled ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.2), value: active)
        .animation(.easeInOut(duration: 0.2), value: masterEnabled)
        .contextMenu {
            Button("Edit override…", action: onEdit)
            if let onMoveUp { Button("Move up", action: onMoveUp) }
            if let onMoveDown { Button("Move down", action: onMoveDown) }
            if !groups.isEmpty {
                Menu("Move to group") {
                    ForEach(groups) { group in
                        Button(group.name.isEmpty ? "Untitled group" : group.name) { onMoveToGroup(group.id) }
                            .disabled(group.id == rule.groupID)
                    }
                    if indented {
                        Divider()
                        Button("No group") { onMoveToGroup(nil) }
                    }
                }
            }
            Divider()
            Button("Duplicate", action: onDuplicate)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
