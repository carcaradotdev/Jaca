import SwiftUI
import Lemonade

/// Create/edit one override rule.
///
/// Seeded from a captured transaction when you right-click a row, or blank from the toolbar.
/// The live match preview at the bottom is the control that makes glob syntax learnable: it
/// answers "what does this pattern actually match?" while you type, against the requests already
/// captured in this tab.
struct OverrideEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: OverrideRule
    @State private var bodyText: String
    @State private var statusText: String
    @State private var delayText: String
    @State private var headers: [HeaderPair]

    let session: NetworkSession
    let overrides: OverridesModel
    let onSave: (OverrideRule) -> Void

    private let isNew: Bool

    init(rule: OverrideRule, session: NetworkSession, overrides: OverridesModel,
         isNew: Bool = false, onSave: @escaping (OverrideRule) -> Void) {
        _draft = State(initialValue: rule)
        self.session = session
        self.overrides = overrides
        self.isNew = isNew
        self.onSave = onSave

        switch rule.action {
        case .respond(let spec):
            _statusText = State(initialValue: String(spec.statusCode))
            _headers = State(initialValue: spec.headers)
            _bodyText = State(initialValue: Self.text(of: spec.body))
        case .editResponse(let edit):
            // Empty means "keep the origin's status". Pre-filling 200 would silently turn that
            // into a hard-coded 200 on the next save.
            _statusText = State(initialValue: edit.statusCode.map(String.init) ?? "")
            _headers = State(initialValue: edit.headers)
            _bodyText = State(initialValue: edit.body.map(Self.text(of:)) ?? "")
        case .mapRemote:
            _statusText = State(initialValue: "200")
            _headers = State(initialValue: [])
            _bodyText = State(initialValue: "")
        }
        _delayText = State(initialValue: String(rule.delayMillis))
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
                        // `onChipClicked:` explicitly: a bare trailing closure backward-matches
                        // `onTrailingIconClick`, which lands on a zero-size button — an inert chip.
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
                LemonadeUi.Notice(
                    content: "This pattern doesn't name a host. Tell Jaca which hosts to route through your Mac — only these leave the device's own network.",
                    voice: .warning)
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
                        // Default to .merge when converting from "Don't send": .replace would
                        // drop every header the real response carries, which is never what
                        // someone switching to "Send and override" means.
                        var edit = currentEdit()
                        if case .editResponse = draft.action {} else { edit.headerMode = .merge }
                        draft.action = .editResponse(edit)
                    }
                }
            )
            .frame(width: 320)

            LemonadeUi.Text(isRespond
                ? "The request never leaves the device. Jaca answers it."
                : "Jaca fetches this URL from your Mac, not from the device. Origins reachable only from the device won't work.",
                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                color: isRespond ? LemonadeTheme.colors.content.contentTertiary
                                 : LemonadeTheme.colors.content.contentCaution,
                maxLines: 3)

            if draft.matcher.kind == .regex {
                LemonadeUi.Notice(content: regexTransportWarning, voice: .info)
            }
        }
    }

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing200) {
            sectionTitle("Response")

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
                LemonadeUi.Text("Headers", textStyle: LemonadeTypography.shared.bodyXSmallMedium,
                                color: LemonadeTheme.colors.content.contentSecondary)
                Spacer()
                // Merge only means something when there's a real response to merge into, so the
                // coupling is enforced here rather than left as a lie in the semantics.
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
                    headers.append(HeaderPair(name: "", value: ""))
                }
            }

            ForEach(Array(headers.enumerated()), id: \.offset) { index, pair in
                HStack(spacing: LemonadeTheme.spaces.spacing100) {
                    TextField("Name", text: Binding(
                        get: { headers[index].name },
                        set: { headers[index] = HeaderPair(name: $0, value: headers[index].value) }))
                        .textFieldStyle(.roundedBorder).font(LogLevelStyle.mono(11))
                    TextField("Value", text: Binding(
                        get: { headers[index].value },
                        set: { headers[index] = HeaderPair(name: headers[index].name, value: $0) }))
                        .textFieldStyle(.roundedBorder).font(LogLevelStyle.mono(11))
                    LemonadeUi.IconButton(icon: .circleX, contentDescription: "Remove header") {
                        headers.remove(at: index)
                    }
                }
            }

            LemonadeUi.Text("Content-Length and Content-Encoding are managed by Jaca.",
                            textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                            color: LemonadeTheme.colors.content.contentTertiary)
        }
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
            // Not `TextEditor`: it inherits AppKit's automatic substitutions, so typing `"`
            // yields a curly quote and silently breaks the JSON body.
            PlainCodeEditor(text: $bodyText)
                .font(LogLevelStyle.mono(11))
                .frame(height: 140)
                .padding(4)
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

    /// A glob whose host is wildcarded (or any regex) can't tell us what to route, so the editor
    /// has to ask. Empty here means Save is blocked — never "route everything".
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

    private var bodyIsValidJSON: Bool {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil
    }

    private var bodyStatusText: String {
        let bytes = Data(bodyText.utf8).count
        let size = NetworkFormatting.size(bytes)
        if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Empty body" }
        return bodyIsValidJSON ? "Valid JSON · \(size)" : "Not valid JSON · \(size) — saved anyway"
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

    /// Keeps the routed-host set in step with a pattern that names a literal host, so the common
    /// case needs no extra input from the user.
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
                             headers: headers.filter { !$0.name.isEmpty },
                             body: OverrideRuleStore.makeBodyRef(Data(bodyText.utf8)))
    }

    /// Rebuilds the edit from the form **without losing fields the form doesn't show**.
    ///
    /// `removeHeaders` has no UI yet, so it must be carried over from the existing rule rather
    /// than reconstructed from scratch — otherwise opening and saving a rule silently discards it.
    private func currentEdit() -> ResponseEdit {
        var edit: ResponseEdit
        if case .editResponse(let existing) = draft.action { edit = existing } else { edit = ResponseEdit() }
        edit.headerMode = headerMode
        edit.headers = headers.filter { !$0.name.isEmpty }
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
