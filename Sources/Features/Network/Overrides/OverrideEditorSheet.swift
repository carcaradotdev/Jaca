import SwiftUI
import Lemonade

/// Create/edit one override rule — seeded from a captured transaction on right-click, or blank
/// from the toolbar. The live match preview at the bottom answers "what does this pattern
/// actually match?" while you type, which is what makes glob syntax learnable.
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
    @State private var showHeaders: Bool
    @State private var bodyStatus = BodyStatus()

    let session: NetworkSession
    let overrides: OverridesModel
    /// Set when this rule was seeded from a captured response that it can't reproduce exactly.
    let seedWarning: String?
    let onSave: (OverrideRule) -> Void

    private let isNew: Bool

    init(rule: OverrideRule, session: NetworkSession, overrides: OverridesModel,
         isNew: Bool = false, seedWarning: String? = nil,
         onSave: @escaping (OverrideRule) -> Void) {
        _draft = State(initialValue: rule)
        self.session = session
        self.overrides = overrides
        self.seedWarning = seedWarning
        self.isNew = isNew
        self.onSave = onSave

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
        // Expanded only when there's something to see — a rule with no headers opens compact.
        switch rule.action {
        case .respond(let spec): _showHeaders = State(initialValue: !spec.headers.isEmpty)
        case .editResponse(let edit): _showHeaders = State(initialValue: !edit.headers.isEmpty)
        case .mapRemote: _showHeaders = State(initialValue: false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
            header
            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)

            ScrollView {
                VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing400) {
                    nameField
                    matchSection
                    actionSection
                    responseSection
                }
                .padding(.horizontal, 2)
            }

            OverrideMatchPreview(draft: draft, session: session, overrides: overrides,
                                 onSelect: { session.selectedID = $0 },
                                 onMoveUp: { overrides.move(draft.id, by: -1) })

            Divider().overlay(LemonadeTheme.colors.border.borderNeutralLow)
            footer
        }
        .onAppear { bodyStatus = Self.status(of: bodyText) }
        .padding(LemonadeTheme.spaces.spacing600)
        .frame(width: 720, height: 640)
        .background(LemonadeTheme.colors.background.bgDefault)
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
                LemonadeUi.Text("Enabled", textStyle: LemonadeTypography.shared.bodySmallRegular,
                                color: LemonadeTheme.colors.content.contentSecondary)
            }
            Spacer()
            if let reason = saveBlockedReason {
                LemonadeUi.Text(reason, textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentCaution, maxLines: 2)
            }
            LemonadeUi.Button(label: "Cancel", onClick: { dismiss() },
                              variant: .neutral, type: .subtle, size: .small)
            LemonadeUi.Button(label: "Save", onClick: save,
                              variant: .primary, type: .solid, size: .small,
                              enabled: saveBlockedReason == nil)
        }
    }

    // MARK: - Fields

    private var nameField: some View {
        LemonadeUi.TextField(input: $draft.name, label: "Name",
                             placeholderText: "Product state stub")
    }

    private var matchSection: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            HStack {
                sectionTitle("Match")
                Spacer()
                LemonadeUi.SegmentedControl(
                    properties: [.label("Glob"), .label("Regex")],
                    selectedTab: draft.matcher.kind == .glob ? 0 : 1,
                    size: .small,
                    onTabSelected: { draft.matcher.kind = $0 == 0 ? .glob : .regex }
                )
                .frame(width: 160)
            }

            LemonadeUi.TextField(input: $draft.matcher.pattern,
                                 onInputChanged: { _ in syncDivertHosts() },
                                 placeholderText: "https://api.example.com/v1/users/*",
                                 errorMessage: patternError, error: patternError != nil)

            if draft.matcher.kind == .glob {
                HStack(spacing: LemonadeTheme.spaces.spacing200) {
                    if canGeneralize {
                        LemonadeUi.Chip(label: "Generalize", selected: false, leadingIcon: .lightning,
                                        onChipClicked: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                draft.matcher.pattern = OverrideMatching.generalize(draft.matcher.pattern)
                                syncDivertHosts()
                            }
                        })
                    }
                    LemonadeUi.Text("`*` one segment · `**` any depth · query ignored unless you write `?`",
                                    textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                    color: LemonadeTheme.colors.content.contentTertiary)
                }
            }

            methodChips

            // Only asked for when the pattern doesn't name a host — we never route "everything".
            if needsExplicitHosts {
                LemonadeUi.Notice(content: transport.hostsNotice, voice: .warning)
                LemonadeUi.TextField(input: divertHostsBinding,
                                     label: "Hosts to route",
                                     placeholderText: "api.example.com, auth.example.com")
            }
        }
    }

    private var methodChips: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing100) {
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

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            sectionTitle("Action")
            LemonadeUi.SegmentedControl(
                properties: [.label("Don't send"), .label("Send and override")],
                selectedTab: isRespond ? 0 : 1,
                size: .small,
                onTabSelected: { index in
                    if index == 0 {
                        draft.action = .respond(currentResponseSpec())
                    } else {
                        // .merge when converting from "Don't send": .replace would drop every
                        // header the real response carries.
                        var edit = currentEdit()
                        if case .editResponse = draft.action {} else { edit.headerMode = .merge }
                        draft.action = .editResponse(edit)
                    }
                }
            )
            .frame(width: 320)

            // "Send and override" fetches from the Mac, which only matters when the Mac and the
            // device are on different networks — so the transport writes the caution, and the
            // Simulator has none.
            if !actionExplainer.isEmpty {
                LemonadeUi.Text(actionExplainer,
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: isRespond ? LemonadeTheme.colors.content.contentTertiary
                                                 : LemonadeTheme.colors.content.contentCaution,
                                maxLines: 3)
                    .transition(.opacity)
            }

            if draft.matcher.kind == .regex {
                LemonadeUi.Notice(content: regexTransportWarning, voice: .info)
            }
        }
        // The caution can appear and disappear, so it fades rather than snapping the section
        // taller — same 0.2s easeInOut as the chips above.
        .animation(.easeInOut(duration: 0.2), value: isRespond)
    }

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            sectionTitle("Response")

            if let seedWarning {
                LemonadeUi.Notice(content: seedWarning, voice: .warning)
            }

            HStack(spacing: LemonadeTheme.spaces.spacing200) {
                LemonadeUi.TextField(input: $statusText, label: "Status")
                    .frame(width: 110)
                HStack(spacing: 4) {
                    ForEach([200, 401, 403, 404, 500, 503], id: \.self) { code in
                        LemonadeUi.Chip(label: "\(code)", selected: statusText == "\(code)",
                                        onChipClicked: { statusText = "\(code)" })
                    }
                }
                Spacer()
                LemonadeUi.TextField(input: $delayText, label: "Delay (ms)")
                    .frame(width: 110)
            }

            headerEditor
            bodyEditor
        }
    }

    private var headerEditor: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
            HStack {
                // Most rules only touch status and body; the count keeps hidden headers visible.
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showHeaders.toggle() } }) {
                    HStack(spacing: 5) {
                        LemonadeUi.Icon(icon: .chevronRight, contentDescription: nil, size: .small,
                                        tint: LemonadeTheme.colors.content.contentTertiary)
                            .rotationEffect(.degrees(showHeaders ? 90 : 0))
                        LemonadeUi.Text(headersLabel,
                                        textStyle: LemonadeTypography.shared.bodyXSmallMedium,
                                        color: LemonadeTheme.colors.content.contentSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showHeaders ? "Hide headers" : "Show headers")

                Spacer()

                if showHeaders {
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
                    .frame(width: 180)
                    .opacity(isRespond ? 0.5 : 1)
                    .help(isRespond ? "Merge needs the real response — choose “Send and override”." : "")

                    LemonadeUi.IconButton(icon: .plus, contentDescription: "Add header") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            headers.append(HeaderRow(name: "", value: ""))
                        }
                    }
                }
            }

            if showHeaders {
                ForEach($headers) { $row in
                    HStack(spacing: LemonadeTheme.spaces.spacing100) {
                        TextField("Name", text: $row.name)
                            .textFieldStyle(.roundedBorder).font(LogLevelStyle.mono(11))
                            .autocorrectionDisabled(true)
                        TextField("Value", text: $row.value)
                            .textFieldStyle(.roundedBorder).font(LogLevelStyle.mono(11))
                            .autocorrectionDisabled(true)
                        LemonadeUi.IconButton(icon: .circleX, contentDescription: "Remove header") {
                            let id = row.id
                            withAnimation(.easeInOut(duration: 0.15)) {
                                headers.removeAll { $0.id == id }
                            }
                        }
                    }
                    .transition(.opacity)
                }

                LemonadeUi.Text("Content-Length and Content-Encoding are managed by Jaca.",
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showHeaders)
    }

    /// The rows as the rule stores them — nameless rows are drafts, not headers.
    private var headerPairs: [HeaderPair] {
        headers.filter { !$0.name.isEmpty }.map { HeaderPair(name: $0.name, value: $0.value) }
    }

    private var headersLabel: String {
        let named = headers.filter { !$0.name.isEmpty }.count
        return named == 0 ? "Headers" : "Headers (\(named))"
    }

    private var bodyEditor: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
            HStack {
                LemonadeUi.Text("Body", textStyle: LemonadeTypography.shared.bodyXSmallMedium,
                                color: LemonadeTheme.colors.content.contentSecondary)
                Spacer()
                LemonadeUi.Button(label: "Format", onClick: formatBody,
                                  variant: .neutral, type: .subtle, size: .small)
            }
            PlainCodeEditor(text: $bodyText)
                .frame(height: 140)
                .task(id: bodyText) {
                    // Debounced: typing shouldn't pay for a full parse per character.
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    bodyStatus = Self.status(of: bodyText)
                }
                .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
                .overlay(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
                    .strokeBorder(LemonadeTheme.colors.border.borderNeutralLow, lineWidth: 1))

            LemonadeUi.Text(bodyStatusText,
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: bodyIsValidJSON ? LemonadeTheme.colors.content.contentTertiary
                                                   : LemonadeTheme.colors.content.contentCaution)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        LemonadeUi.Text(text.uppercased(), textStyle: LemonadeTypography.shared.bodyXSmallMedium,
                        color: LemonadeTheme.colors.content.contentTertiary)
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
            && OverrideCompiler.derivedDivertHosts(for: draft.matcher).isEmpty
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
        if needsExplicitHosts && draft.divertHosts.isEmpty {
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

    private var divertHostsBinding: Binding<String> {
        Binding(
            get: { draft.divertHosts.sorted().joined(separator: ", ") },
            set: { text in
                draft.divertHosts = Set(text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty })
            }
        )
    }

    // MARK: - Actions

    /// Keeps the routed-host set in step with a pattern that names a literal host.
    private func syncDivertHosts() {
        let derived = OverrideCompiler.derivedDivertHosts(for: draft.matcher)
        if !derived.isEmpty { draft.divertHosts = derived }
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
            rule.divertHosts = [seedHost.lowercased()]
        }
        return rule
    }

    private static func text(of ref: OverrideBodyRef) -> String {
        guard let data = OverrideBodyLoader.data(for: ref) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
