import SwiftUI
import AppKit
import Lemonade

/// Create/edit one override rule — seeded from a captured transaction on right-click, or blank
/// from the toolbar. The live match preview under the pattern answers "what does this pattern
/// actually match?" while you type, which is what makes glob syntax learnable.
///
/// Two columns: the rule's settings on the left, and the response content on the right at full
/// height, as Body and Headers tabs. The body is what most people open this to edit; stacked under
/// the settings it either sat below the fold or squeezed the settings until Action and Status did.
struct OverrideEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// One editable header row. `HeaderPair` can't identify one: its `id` is `name + ":" + value`,
    /// which changes per keystroke and collides for blank rows. Keying on the array offset was
    /// worse — `TextField` bindings capture it, so a removal left closures indexing out of bounds.
    private struct HeaderRow: Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    @State private var draft: OverrideRule
    @State private var bodyText: String
    @State private var statusText: String
    @State private var delayText: String
    @State private var headers: [HeaderRow]
    /// Body first: it's what most rules change, and a seeded rule copies every response header —
    /// often twenty or more — which used to open expanded and push the body away.
    @State private var responseTab: ResponseTab = .body
    @State private var bodyStatus = BodyStatus()
    /// Whether `draft.routedHosts` came from the pattern; see `RoutedHostsSync`.
    @State private var hostsDerived: Bool
    @State private var find = CodeEditorFind()

    /// Not persisted: reopening maximised would hide the pattern field, the one required field.
    @State private var bodyMaximised = false

    private enum ResponseTab: Int { case body, headers }

    let session: NetworkSession
    let overrides: OverridesModel
    /// Set when this rule was seeded from a captured response that it can't reproduce exactly.
    let seedWarning: String?
    let onSave: (OverrideRule) -> Void

    private let isNew: Bool
    /// Sized once, from the screen the sheet opens on. A `@State` set later would resize the dialog
    /// after it appeared.
    private let sheetSize: CGSize
    /// What "Don't send" opened with, so switching to "Send and override" can tell values the user
    /// chose from ones they never touched. See `dropUntouchedResponseDefaults`.
    private let openedAsRespond: Bool
    private let initialStatusText: String
    private let initialHeaderPairs: [HeaderPair]

    init(rule: OverrideRule, session: NetworkSession, overrides: OverridesModel,
         isNew: Bool = false, seedWarning: String? = nil,
         onSave: @escaping (OverrideRule) -> Void) {
        _draft = State(initialValue: rule)
        self.session = session
        self.overrides = overrides
        self.seedWarning = seedWarning
        self.isNew = isNew
        self.onSave = onSave
        let screen = NSScreen.main?.visibleFrame
        self.sheetSize = CGSize(width: OverrideEditorLayout.sheetWidth(visibleWidth: screen?.width),
                                height: OverrideEditorLayout.sheetHeight(visibleHeight: screen?.height))
        _hostsDerived = State(initialValue: RoutedHostsSync.initial(
            hosts: rule.routedHosts,
            derived: OverrideCompiler.derivedRoutedHosts(for: rule.matcher)).isDerived)

        switch rule.action {
        case .respond(let spec):
            _statusText = State(initialValue: String(spec.statusCode))
            _headers = State(initialValue: spec.headers.map { HeaderRow(name: $0.name, value: $0.value) })
            _bodyText = State(initialValue: Self.text(of: spec.body))
        case .editResponse(let edit):
            // Empty means "keep the origin's status"; pre-filling 200 would hard-code it.
            _statusText = State(initialValue: edit.statusCode.map(String.init) ?? "")
            _headers = State(initialValue: edit.headers.map { HeaderRow(name: $0.name, value: $0.value) })
            _bodyText = State(initialValue: edit.body.map(Self.text(of:)) ?? "")
        case .mapRemote:
            _statusText = State(initialValue: "200")
            _headers = State(initialValue: [])
            _bodyText = State(initialValue: "")
        }
        _delayText = State(initialValue: String(rule.delayMillis))

        // Mirrors the seeding above; read from the rule rather than `_statusText`, which isn't
        // installed on a view yet.
        switch rule.action {
        case .respond(let spec):
            openedAsRespond = true
            initialStatusText = String(spec.statusCode)
            initialHeaderPairs = spec.headers.filter { !$0.name.isEmpty }
        case .editResponse(let edit):
            openedAsRespond = false
            initialStatusText = edit.statusCode.map(String.init) ?? ""
            initialHeaderPairs = edit.headers.filter { !$0.name.isEmpty }
        case .mapRemote:
            openedAsRespond = false
            initialStatusText = "200"
            initialHeaderPairs = []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            header
            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)

            // Side by side. Stacked, the settings and the body fought over one column: giving the
            // body room left the settings ~300pt, with Action and Status below the fold of their own
            // scroll view. Here each gets the full height.
            HStack(alignment: .top, spacing: LemonadeTheme.spaces.spacing500) {
                if !bodyMaximised {
                    ScrollView {
                        settingsForm
                            // Clear of the scroller, which overlays content on macOS.
                            .padding(.trailing, LemonadeTheme.spaces.spacing300)
                    }
                    .frame(width: OverrideEditorLayout.settingsWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
                        .transition(.opacity)
                }
                responsePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
            footer
        }
        .background { findShortcuts }
        // While the find bar is open, Esc belongs to it, wherever focus is.
        .interactiveDismissDisabled(find.isVisible)
        .onAppear { bodyStatus = Self.status(of: bodyText) }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: sheetSize.width, height: sheetSize.height)
        .background(LemonadeTheme.colors.background.bgDefault)
    }

    /// A second route for the find shortcuts. `FindableTextView.performKeyEquivalent` handles them
    /// without focus, but whether SwiftUI's hosting view forwards key equivalents into a
    /// representable's subviews has varied across releases. Dispatch stops at the first handler and
    /// both routes call the same idempotent methods, so whichever fires is fine.
    private var findShortcuts: some View {
        Group {
            // Each switches to the Body tab first: the find bar lives on the body editor, so from
            // the Headers tab it would otherwise open on nothing.
            Button("") { showBody(); find.show() }
                .keyboardShortcut("f", modifiers: .command).hidden()
            Button("") { showBody(); find.step(by: 1) }
                .keyboardShortcut("g", modifiers: .command).hidden()
            Button("") { showBody(); find.step(by: -1) }
                .keyboardShortcut("g", modifiers: [.command, .shift]).hidden()
            // Esc closes the find bar, not the sheet. The bar's own `onExitCommand` only fires with
            // focus inside it, and the editor's `cancelOperation` only with focus there; from any
            // other field Esc used to dismiss the sheet. Present only while the bar is open, so Esc
            // still closes the sheet otherwise.
            if find.isVisible {
                Button("") { find.hide() }
                    .keyboardShortcut(.cancelAction).hidden()
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack {
            LemonadeUi.Text(isNew ? "New response override" : "Edit response override",
                            textStyle: LemonadeTypography.shared.headingSmall,
                            color: LemonadeTheme.colors.content.contentPrimary)
            Spacer()
            LemonadeUi.IconButton(icon: .circleX, contentDescription: "Close") { dismiss() }
        }
    }

    private var footer: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing300) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Switch(checked: draft.enabled) { draft.enabled = $0 }
                // The label is part of the control, as with a system checkbox.
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { draft.enabled.toggle() } }) {
                    LemonadeUi.Text("Enabled", textStyle: LemonadeTypography.shared.bodySmallRegular,
                                    color: LemonadeTheme.colors.content.contentSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let reason = saveBlockedReason {
                LemonadeUi.Text(reason, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentCaution, maxLines: 2)
            }
            // `fixedSize`: a Lemonade button fills the width it's offered, so beside a Spacer each
            // took half the footer.
            LemonadeUi.Button(label: "Cancel", onClick: { dismiss() },
                              variant: .neutral, type: .subtle, size: .small)
                .fixedSize()
            LemonadeUi.Button(label: "Save", onClick: save,
                              variant: .primary, type: .solid, size: .small,
                              enabled: saveBlockedReason == nil)
                .fixedSize()
                // ⌘↩ rather than Return: Return has to insert a newline in the body editor.
                .keyboardShortcut(.return, modifiers: .command)
                .help("Save (⌘↩)")
        }
    }

    // MARK: - Fields

    /// Every setting as a labelled row: labels in their own trailing-aligned column, controls in the
    /// second. With the labels out of the controls, every field in a row is a bare input of the same
    /// height, so the status chips centre on the status box. When each field carried its label above
    /// its input, centring put the chips level with the labels, and bottom-aligning only worked if
    /// the chips' box matched Lemonade's padded input height, which it didn't.
    private var settingsForm: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            row("Name") {
                LemonadeUi.TextField(input: $draft.name, placeholderText: "Product state stub")
            }

            // MARK: Match
            row("Match") {
                // The error has its own row below, rather than as the field's support text: support
                // text makes the cell taller and the centred label drifts off the input.
                LemonadeUi.TextField(input: $draft.matcher.pattern,
                                     onInputChanged: { _ in syncRoutedHosts() },
                                     placeholderText: "https://api.example.com/v1/users/*",
                                     error: patternError != nil)
            }
            if let patternError {
                row(nil) {
                    LemonadeUi.Text(patternError, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: LemonadeTheme.colors.content.contentCritical, maxLines: 2)
                }
                .transition(.opacity)
            }
            row(nil) {
                HStack(spacing: LemonadeTheme.spaces.spacing300) {
                    LemonadeUi.SegmentedControl(
                        properties: [.label("Glob"), .label("Regex")],
                        selectedTab: draft.matcher.kind == .glob ? 0 : 1,
                        size: .small,
                        onTabSelected: {
                            draft.matcher.kind = $0 == 0 ? .glob : .regex
                            // A regex names no host, so hosts derived from the glob are now stale.
                            syncRoutedHosts()
                        }
                    )
                    .frame(width: 140)
                    if draft.matcher.kind == .glob && canGeneralize {
                        LemonadeUi.Chip(label: "Generalize", selected: false, leadingIcon: .lightning,
                                        onChipClicked: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                draft.matcher.pattern = OverrideMatching.generalize(draft.matcher.pattern)
                                syncRoutedHosts()
                            }
                        })
                        .transition(.opacity)
                    }
                }
            }
            row(nil) {
                methodChips
            }
            if draft.matcher.kind == .glob {
                row(nil) {
                    LemonadeUi.Text("`*` one segment · `**` any depth · query ignored unless you write `?`",
                                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: LemonadeTheme.colors.content.contentTertiary)
                }
                .transition(.opacity)
            }
            row(nil) {
                // Under the pattern it explains. Pinned above the footer it cost the body ~80pt
                // whether or not anyone was reading it.
                OverrideMatchPreview(draft: draft, session: session, overrides: overrides,
                                     onSelect: { session.selectedID = $0 },
                                     onMoveUp: { overrides.move(draft.id, by: -1) })
            }
            // Only asked for when the pattern doesn't name a host — we never route "everything".
            if needsExplicitHosts {
                row(nil) {
                    LemonadeUi.Notice(content: transport.hostsNotice, voice: .warning)
                }
                .transition(.opacity)
                row("Hosts to route") {
                    LemonadeUi.TextField(input: routedHostsBinding,
                                         placeholderText: "api.example.com, auth.example.com")
                }
                .transition(.opacity)
            }

            // What to match above, what to send below.
            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
                .padding(.vertical, LemonadeTheme.spaces.spacing100)

            // MARK: Response
            row("Action") {
                LemonadeUi.SegmentedControl(
                    properties: [.label("Don't send"), .label("Send and override")],
                    selectedTab: isRespond ? 0 : 1,
                    size: .small,
                    onTabSelected: { index in
                        if index == 0 {
                            draft.action = .respond(currentResponseSpec())
                        } else {
                            if isRespond { dropUntouchedResponseDefaults() }
                            // .merge when converting from "Don't send": .replace would drop every
                            // header the real response carries.
                            var edit = currentEdit()
                            if case .editResponse = draft.action {} else { edit.headerMode = .merge }
                            draft.action = .editResponse(edit)
                        }
                    }
                )
                .frame(width: 300)
            }
            // "Send and override" fetches from the Mac, which only matters when the Mac and the
            // device are on different networks — so the transport writes the caution, and the
            // Simulator has none.
            if !actionExplainer.isEmpty {
                row(nil) {
                    LemonadeUi.Text(actionExplainer,
                                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: isRespond ? LemonadeTheme.colors.content.contentTertiary
                                                     : LemonadeTheme.colors.content.contentCaution,
                                    maxLines: 3)
                        // The sentence changes with the action without the row coming or going, so
                        // it cross-fades its text rather than relying on an insertion transition.
                        .contentTransition(.opacity)
                }
            }
            if draft.matcher.kind == .regex {
                row(nil) {
                    LemonadeUi.Notice(content: regexTransportWarning, voice: .info)
                }
                .transition(.opacity)
            }
            if let seedWarning {
                row(nil) {
                    LemonadeUi.Notice(content: seedWarning, voice: .warning)
                }
            }
            row("Status") {
                // Empty means 200 when Jaca answers, and the origin's own status when it overrides.
                // Same field, opposite meanings, so the placeholder says which.
                LemonadeUi.TextField(input: $statusText,
                                     placeholderText: isRespond ? "200" : "Original")
                    .frame(width: 104)
            }
            row(nil) {
                FlowLayout(spacing: LemonadeTheme.spaces.spacing100, lineSpacing: LemonadeTheme.spaces.spacing100) {
                    ForEach([200, 401, 403, 404, 500, 503], id: \.self) { code in
                        LemonadeUi.Chip(label: "\(code)", selected: statusText == "\(code)",
                                        onChipClicked: { statusText = "\(code)" })
                    }
                }
            }
            row("Delay (ms)") {
                LemonadeUi.TextField(input: $delayText, placeholderText: "0")
                    .frame(width: 104)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: needsExplicitHosts)
        .animation(.easeInOut(duration: 0.2), value: draft.matcher.kind)
        .animation(.easeInOut(duration: 0.2), value: patternError)
        .animation(.easeInOut(duration: 0.2), value: isRespond)
        .animation(.easeInOut(duration: 0.2), value: canGeneralize)
    }

    private func rowLabel(_ text: String) -> some View {
        // Leading, so labels start on the same edge as the dividers. Trailing-aligned, they left a
        // dead gutter between the sheet's edge and the shortest labels.
        LemonadeUi.Text(text, textStyle: LemonadeTypography.shared.bodySmallMedium, textAlign: .leading,
                        color: LemonadeTheme.colors.content.contentSecondary, maxLines: 2)
            .frame(width: OverrideEditorLayout.labelWidth, alignment: .leading)
    }

    /// One settings row: a fixed-width label column, then the controls filling the rest. Plain
    /// stacks rather than a `Grid`, which sized the label column from every cell in it and came out
    /// half as wide again as the labels, squeezing the chips onto second lines.
    private func row<Content: View>(_ label: String?, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: LemonadeTheme.spaces.spacing400) {
            if let label {
                rowLabel(label)
            } else {
                Color.clear.frame(width: OverrideEditorLayout.labelWidth, height: 0)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Wraps rather than overflowing if the column is ever narrower than the six chips.
    private var methodChips: some View {
        FlowLayout(spacing: LemonadeTheme.spaces.spacing100, lineSpacing: LemonadeTheme.spaces.spacing100) {
            LemonadeUi.Chip(label: "ANY", selected: draft.matcher.methods.isEmpty,
                            onChipClicked: { draft.matcher.methods = [] })
            ForEach(["GET", "POST", "PUT", "PATCH", "DELETE"], id: \.self) { method in
                LemonadeUi.Chip(label: method, selected: draft.matcher.methods.contains(method),
                                onChipClicked: {
                    if draft.matcher.methods.contains(method) { draft.matcher.methods.remove(method) }
                    else { draft.matcher.methods.insert(method) }
                })
            }
        }
    }

    // MARK: - Response pane

    /// Body and headers as tabs over one full-height area, with each tab's own tools on the right of
    /// the tab row.
    private var responsePane: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing300) {
            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.Tabs(tabs: [LemonadeTabItem(label: "Body"), LemonadeTabItem(label: headersLabel)],
                                selectedIndex: responseTab.rawValue,
                                onTabSelected: { select(ResponseTab(rawValue: $0) ?? .body) },
                                showDivider: false)
                    .fixedSize()
                Spacer(minLength: LemonadeTheme.spaces.spacing300)
                switch responseTab {
                case .body: bodyTools
                case .headers: headerTools
                }
            }

            switch responseTab {
            case .body:
                VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
                    if find.isVisible {
                        CodeEditorFindBar(find: find)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    bodyEditor
                    // A status line under the editor, flush with its edge. In the tab row it shared
                    // a line with the tabs and tools, sat off their centre line and got truncated.
                    LemonadeUi.Text(bodyStatusText,
                                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: bodyIsValidJSON ? LemonadeTheme.colors.content.contentTertiary
                                                           : LemonadeTheme.colors.content.contentCaution,
                                    maxLines: 1)
                }
                .animation(.easeInOut(duration: 0.2), value: find.isVisible)
                .transition(.opacity)
            case .headers:
                headersTable.transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: responseTab)
    }

    /// Few enough headers that the table shows them all without scrolling.
    private var headersFit: Bool { headers.count <= 12 }

    private func select(_ tab: ResponseTab) {
        guard tab != responseTab else { return }
        // The find bar belongs to the body editor, which is about to go.
        if tab != .body { find.hide() }
        responseTab = tab
    }

    private func showBody() { select(.body) }

    private var bodyTools: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.IconButton(icon: .search, contentDescription: "Find in body",
                                  onClick: { find.show() }, size: .small)
                .help("Find (⌘F)")
            LemonadeUi.Button(label: "Format", onClick: formatBody,
                              variant: .neutral, type: .subtle, size: .small)
                .fixedSize()
            // Lemonade has no toggle-button state, so the icon carries it.
            LemonadeUi.IconButton(
                icon: bodyMaximised ? .chevronsDownUp : .maximize,
                contentDescription: bodyMaximised ? "Collapse the body editor" : "Expand the body editor",
                onClick: { withAnimation(.easeInOut(duration: 0.22)) { bodyMaximised.toggle() } },
                size: .small)
                .help(bodyMaximised ? "Collapse the body editor" : "Expand the body editor")
        }
        .transition(.opacity)
    }

    private var headerTools: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            // Merge only means something when there's a real response to merge into.
            LemonadeUi.SegmentedControl(
                properties: [.label("Replace"), .label("Merge")],
                selectedTab: headerMode == .replace ? 0 : 1,
                size: .small,
                onTabSelected: { index in
                    guard !isRespond || index == 0 else { return }
                    setHeaderMode(index == 0 ? .replace : .merge)
                }
            )
            .frame(width: 160)
            .opacity(isRespond ? 0.5 : 1)
            .help(isRespond ? "Merge needs the real response — choose “Send and override”." : "")

            LemonadeUi.IconButton(icon: .plus, contentDescription: "Add header",
                                  onClick: {
                                      withAnimation(.easeInOut(duration: 0.15)) {
                                          headers.append(HeaderRow(name: "", value: ""))
                                      }
                                  },
                                  type: .ghost, size: .small)
                .help("Add header")
        }
        .transition(.opacity)
    }

    /// A compact two-column table (name, value) with a small remove button per row. Full-size inputs
    /// made each header a 48pt row, so a seeded rule's two dozen headers filled the sheet.
    private var headersTable: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            if !headers.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(headers.enumerated()), id: \.element.id) { offset, row in
                            if offset > 0 {
                                Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
                            }
                            headerRow(id: row.id)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                .overlay(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
                // Hugs the rows when there are few, scrolls when there are many. While it hugs, the
                // scroller is off: otherwise it flashed in for the length of every add/remove
                // animation, as the content and the frame grew a frame apart.
                .fixedSize(horizontal: false, vertical: headersFit)
                .scrollIndicators(headersFit ? .hidden : .automatic)
                .scrollDisabled(headersFit)
            }

            LemonadeUi.Text("Content-Length and Content-Encoding are managed by Jaca.",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One header in the table: name | value | remove. Bound by id, never by offset, so a removal
    /// can't leave a field writing to the wrong row (see `HeaderRow`).
    private func headerRow(id: UUID) -> some View {
        HStack(spacing: 0) {
            TextField("Name", text: headerBinding(id, \.name))
                .textFieldStyle(.plain).font(LogLevelStyle.mono(11))
                .autocorrectionDisabled(true)
                .padding(.horizontal, LemonadeTheme.spaces.spacing200)
                .frame(width: 200, alignment: .leading)
            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
            TextField("Value", text: headerBinding(id, \.value))
                .textFieldStyle(.plain).font(LogLevelStyle.mono(11))
                .autocorrectionDisabled(true)
                .padding(.horizontal, LemonadeTheme.spaces.spacing200)
                .frame(maxWidth: .infinity, alignment: .leading)
            LemonadeUi.IconButton(icon: .times, contentDescription: "Remove header",
                                  onClick: {
                                      withAnimation(.easeInOut(duration: 0.15)) {
                                          headers.removeAll { $0.id == id }
                                      }
                                  },
                                  type: .ghost, size: .xSmall)
                .padding(.trailing, LemonadeTheme.spaces.spacing100)
        }
        .frame(height: 30)
        .transition(.opacity)
    }

    private func headerBinding(_ id: UUID, _ field: WritableKeyPath<HeaderRow, String>) -> Binding<String> {
        Binding(
            get: { headers.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { newValue in
                guard let index = headers.firstIndex(where: { $0.id == id }) else { return }
                headers[index][keyPath: field] = newValue
            })
    }

    /// The rows as the rule stores them — nameless rows are drafts, not headers.
    private var headerPairs: [HeaderPair] {
        headers.filter { !$0.name.isEmpty }.map { HeaderPair(name: $0.name, value: $0.value) }
    }

    private var headersLabel: String {
        let named = headers.filter { !$0.name.isEmpty }.count
        return named == 0 ? "Headers" : "Headers (\(named))"
    }

    /// The editor fills the pane.
    private var bodyEditor: some View {
        PlainCodeEditor(text: $bodyText, find: find)
            .frame(maxHeight: .infinity)
            .task(id: bodyText) {
                // Debounced: typing shouldn't pay for a full parse per character.
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                bodyStatus = Self.status(of: bodyText)
            }
            // The same 200ms debounce lives inside `refresh`. The id carries the body, so Format
            // rewriting it under an open bar takes the same path as typing.
            .task(id: find.request(for: bodyText)) { await find.refresh(in: bodyText) }
            .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
            .overlay(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                .strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))
    }

    // MARK: - Derived

    private var isRespond: Bool { if case .respond = draft.action { return true }; return false }

    private var headerMode: ResponseEdit.HeaderMode {
        if case .editResponse(let edit) = draft.action { return edit.headerMode }
        // "Don't send" fabricates the whole response, so its headers are the response — the
        // segmented control shows Replace, and is disabled.
        return .replace
    }

    private var canGeneralize: Bool {
        OverrideMatching.generalize(draft.matcher.pattern) != draft.matcher.pattern
    }

    /// A wildcarded host (or any regex) can't tell us what to route, so the editor asks. Empty
    /// blocks Save — never "route everything".
    private var needsExplicitHosts: Bool {
        !draft.matcher.pattern.isEmpty
            && OverrideCompiler.derivedRoutedHosts(for: draft.matcher).isEmpty
    }

    private var patternError: String? {
        guard !draft.matcher.pattern.isEmpty else { return nil }
        switch draft.matcher.kind {
        case .glob:
            if case .failure = OverrideMatching.compileGlob(draft.matcher.pattern) {
                return "This pattern isn't valid."
            }
            return nil
        case .regex:
            let anchored = OverrideCompiler.anchor(draft.matcher.pattern)
            do { _ = try NSRegularExpression(pattern: anchored); return nil }
            catch { return error.localizedDescription }
        }
    }

    /// The interception point this tab captures through; keys every platform-specific sentence.
    private var transport: InterceptTransportID { session.interceptTransport }

    private var actionExplainer: String {
        isRespond ? "The request never leaves the device. Jaca answers it."
                  : transport.originExplainer
    }

    private var regexTransportWarning: String {
        "Regex matching runs on your Mac. It applies wherever Jaca terminates the request — "
        + "in-process agent capture and HTTPS decryption — but a rule still needs a host to route."
    }

    private var saveBlockedReason: String? {
        if draft.matcher.pattern.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter a URL or pattern to match."
        }
        if patternError != nil { return "Fix the pattern to save." }
        if needsExplicitHosts && draft.routedHosts.isEmpty {
            return "Add at least one host to route."
        }
        return nil
    }

    /// Recomputed off the keystroke path — see `bodyStatus`.
    private var bodyIsValidJSON: Bool { bodyStatus.isValidJSON }

    private var bodyStatusText: String {
        if bodyStatus.isEmpty { return "Empty body" }
        let size = NetworkFormatting.size(bodyStatus.byteCount)
        return bodyStatus.isValidJSON ? "Valid JSON · \(size)"
                                      : "Not valid JSON · \(size) — saved anyway"
    }

    /// Parses `bodyText` and measures it. Kept out of `body`, where every keystroke re-parsed the
    /// whole document on the main thread — the status line is advisory, so it can lag the caret.
    static func status(of text: String) -> BodyStatus {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return BodyStatus(isEmpty: true, isValidJSON: true, byteCount: 0) }
        let valid = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
        return BodyStatus(isEmpty: false, isValidJSON: valid, byteCount: Data(text.utf8).count)
    }

    struct BodyStatus: Equatable {
        var isEmpty = true
        var isValidJSON = true
        var byteCount = 0
    }

    private var routedHostsBinding: Binding<String> {
        Binding(
            get: { draft.routedHosts.sorted().joined(separator: ", ") },
            set: { text in
                let typed = Set(text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty })
                let next = RoutedHostsSync.afterUserEdit(hosts: typed)
                draft.routedHosts = next.hosts
                hostsDerived = next.isDerived
            }
        )
    }

    // MARK: - Actions

    /// Keeps the routed-host set in step with the matcher, including dropping hosts derived from
    /// an earlier pattern once the current one no longer names a host.
    private func syncRoutedHosts() {
        let next = RoutedHostsSync.afterMatcherChange(
            .init(hosts: draft.routedHosts, isDerived: hostsDerived),
            derived: OverrideCompiler.derivedRoutedHosts(for: draft.matcher))
        draft.routedHosts = next.hosts
        hostsDerived = next.isDerived
    }

    /// "Send and override" treats a status or header as an override of the real one, and should start
    /// as a no-op. What "Don't send" opened with — a new rule's 200 and JSON Content-Type, or a
    /// captured response's snapshot — was never chosen as an override, yet carrying it across
    /// hard-coded 200 over the origin's status (hiding the 4xx/5xx someone is usually after) and
    /// replaced its Content-Type. Only values changed in this sitting carry over. The body does carry:
    /// it's on screen, and it's usually the captured body the user switched modes to tweak.
    private func dropUntouchedResponseDefaults() {
        guard openedAsRespond else { return }
        if statusText == initialStatusText { statusText = "" }
        if headerPairs == initialHeaderPairs {
            withAnimation(.easeInOut(duration: 0.15)) { headers = [] }
        }
    }

    private func formatBody() {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { bodyText = text }
    }

    private func currentResponseSpec() -> OverrideResponseSpec {
        OverrideResponseSpec(statusCode: Int(statusText) ?? 200,
                             headers: headerPairs,
                             body: OverrideRuleStore.makeBodyRef(Data(bodyText.utf8)))
    }

    /// Rebuilds the edit from the form **without losing fields the form doesn't show**:
    /// `removeHeaders` has no UI yet, so opening and saving would otherwise discard it.
    private func currentEdit() -> ResponseEdit {
        var edit: ResponseEdit
        if case .editResponse(let existing) = draft.action { edit = existing } else { edit = ResponseEdit() }
        edit.headerMode = headerMode
        edit.headers = headerPairs
        // An empty status field means "keep the origin's status" (the field is optional), not 200.
        edit.statusCode = statusText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Int(statusText)
        edit.body = bodyText.isEmpty ? nil : OverrideRuleStore.makeBodyRef(Data(bodyText.utf8))
        return edit
    }

    private func setHeaderMode(_ mode: ResponseEdit.HeaderMode) {
        guard case .editResponse(var edit) = draft.action else { return }
        edit.headerMode = mode
        draft.action = .editResponse(edit)
    }

    private func save() {
        var rule = draft
        rule.delayMillis = Int(delayText) ?? 0
        rule.action = isRespond ? .respond(currentResponseSpec()) : .editResponse(currentEdit())
        if rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
            rule.name = rule.matcher.pattern
        }
        onSave(rule)
        dismiss()
    }

    // MARK: - Seeding

    /// A blank rule for the "create without a captured request" path.
    static func blankRule(seedHost: String?) -> OverrideRule {
        var rule = OverrideRule()
        if let seedHost, !seedHost.isEmpty {
            rule.matcher.pattern = "https://\(seedHost)/"
            rule.routedHosts = [seedHost.lowercased()]
        }
        return rule
    }

    private static func text(of ref: OverrideBodyRef) -> String {
        guard let data = OverrideBodyLoader.data(for: ref) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
