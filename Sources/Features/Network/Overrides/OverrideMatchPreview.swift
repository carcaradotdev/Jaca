import SwiftUI
import Lemonade

/// Live feedback on what a pattern actually matches, checked against this tab's captured
/// requests — which is what makes the matcher learnable. It also surfaces *shadowing*: a rule
/// that matches but never fires because an earlier one wins.
struct OverrideMatchPreview: View {
    let draft: OverrideRule
    let session: NetworkSession
    let overrides: OverridesModel
    let onSelect: (UUID) -> Void
    let onMoveUp: () -> Void

    @State private var debounced: String = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var result = MatchResult()

    /// One scan's worth of answers. As three computed properties each recompiled the glob and
    /// rescanned `session.transactions`, so every render — including typing a name — cost three
    /// full passes, whatever the debounce gated.
    private struct MatchResult {
        /// Only what the view renders. Holding every match kept a second reference to each
        /// `NetworkTransaction`, bodies included, for as long as the sheet was open.
        var examples: [NetworkTransaction] = []
        var total: Int = 0
        var shadowed: Int = 0
    }

    private static let exampleLimit = 3

    /// Everything a rescan depends on; nothing else in the draft may trigger one. The capture
    /// count is *bucketed* because keying on the exact count reran the O(n) scan per arriving
    /// row — O(n²) over a busy session with the sheet open.
    private struct MatchKey: Equatable {
        var pattern: String
        var kind: OverrideMatcher.Kind
        var methods: [String]
        var transactionBucket: Int
        var ruleOrder: [UUID]
        var enabled: [Bool]
    }

    private var matchKey: MatchKey {
        MatchKey(pattern: debounced,
                 kind: draft.matcher.kind,
                 methods: draft.matcher.methods.sorted(),
                 transactionBucket: session.transactions.count / 50,
                 ruleOrder: overrides.rules.map(\.id),
                 enabled: overrides.rules.map(\.enabled))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LemonadeTheme.spaces.spacing100) {
            summaryLine
            ForEach(result.examples, id: \.id) { txn in
                Button(action: { onSelect(txn.id) }) {
                    HStack(spacing: 6) {
                        Text(txn.method)
                            .font(LogLevelStyle.mono(10))
                            .foregroundStyle(LemonadeTheme.colors.content.contentSecondary)
                            .frame(width: 46, alignment: .leading)
                        Text(txn.url)
                            .font(LogLevelStyle.mono(10))
                            .foregroundStyle(LemonadeTheme.colors.content.contentTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LemonadeTheme.spaces.spacing200)
        .background(RoundedRectangle(cornerRadius: LemonadeTheme.radius.radius150)
            .fill(LemonadeTheme.colors.background.bgNeutralSubtle))
        .onChange(of: draft.matcher.pattern) { _, newValue in schedule(newValue) }
        .onChange(of: draft.matcher.kind) { _, _ in schedule(draft.matcher.pattern) }
        .onAppear { debounced = draft.matcher.pattern }
        .task(id: matchKey) { result = computeMatches() }
    }

    private var summaryLine: some View {
        let total = session.transactions.count
        let count = result.total
        let shadowed = result.shadowed

        return Group {
            if draft.matcher.pattern.isEmpty {
                LemonadeUi.Text("Enter a pattern to see what it matches.",
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentTertiary)
            } else if count == 0 {
                // Never a blocker: writing a rule for an endpoint you haven't hit yet is normal.
                LemonadeUi.Text("Nothing captured so far matches this pattern. It will still apply to future requests.",
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: LemonadeTheme.colors.content.contentCaution, maxLines: 2)
            } else {
                HStack(spacing: 6) {
                    Text("Matches \(count) of \(total) captured")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(LemonadeTheme.colors.content.contentPrimary)
                        .contentTransition(.numericText())
                    if shadowed > 0 {
                        Text("· \(shadowed) shadowed")
                            .font(.system(size: 11))
                            .foregroundStyle(LemonadeTheme.colors.content.contentCaution)
                        Button("Move this rule up", action: onMoveUp)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                .help(shadowed > 0
                      ? "Another enabled rule above this one already handles \(shadowed) of these requests."
                      : "")
            }
        }
    }

    // MARK: - Matching against the captured buffer

    /// Compiled from the **debounced** pattern: reading `draft` here makes the debounce inert.
    private var compiledDraft: CompiledRule? {
        var rule = draft
        rule.enabled = true
        rule.matcher.pattern = debounced
        return OverrideCompiler.compile([rule], masterEnabled: true).rules.first
    }

    /// One pass over the buffer: one glob compile, one URL parse per row, both answers.
    /// Shadowing is "this matches, but an **earlier enabled** rule already handles it".
    private func computeMatches() -> MatchResult {
        guard !debounced.isEmpty, let compiled = compiledDraft else { return MatchResult() }

        let snapshot = overrides.compiled
        let index = overrides.rules.firstIndex { $0.id == draft.id }
        let earlier: Set<UUID> = index.map { Set(overrides.rules.prefix($0).filter(\.enabled).map(\.id)) } ?? []

        var out = MatchResult()
        for txn in session.transactions {
            guard let facts = OverrideMatching.facts(url: txn.url),
                  OverrideMatching.matches(compiled, facts, method: txn.method) else { continue }
            out.total += 1
            if out.examples.count < Self.exampleLimit { out.examples.append(txn) }
            guard !earlier.isEmpty,
                  let winner = snapshot.firstMatch(facts: facts, method: txn.method,
                                                   deviceID: nil, appID: nil) else { continue }
            if earlier.contains(winner.id) { out.shadowed += 1 }
        }
        return out
    }

    private func schedule(_ pattern: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation(.easeInOut(duration: 0.15)) { debounced = pattern } }
        }
    }
}
