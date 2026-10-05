import SwiftUI
import AppKit
import Lemonade

/// Find-in-text for `PlainCodeEditor`: the bar's state, and the only handle on the editor's
/// `NSTextView`.
///
/// The text view never has to be first responder for this to work. The search reads a `String` the
/// host already owns and writes back selection, scroll position and *temporary* attributes. That is
/// why this isn't AppKit's own find bar: it answers ⌘F only once its text view holds focus (in a
/// sheet the user has usually just been typing in another field), it comes from an Edit ▸ Find menu
/// item this app doesn't have, it can't be themed, and it can't show a match count.
@MainActor @Observable
final class CodeEditorFind {
    var isVisible = false
    var query = ""
    /// Off by default: a case-sensitive default makes searching a body for a key you half-remember
    /// come up empty for the wrong reason.
    var caseSensitive = false

    private(set) var result = TextSearch.Result.none
    private(set) var index = 0

    /// Where the next recompute starts looking. Moves with every jump.
    @ObservationIgnored private var anchor = 0
    /// The query a result was last revealed for. A recompute caused only by the body changing must
    /// not move the selection: with the bar open, every edit would otherwise snap the caret to a
    /// match 200ms after the user typed.
    @ObservationIgnored private var revealedFor: (query: String, caseSensitive: Bool)?
    /// Not observed: a back-channel to the editor, never something the UI renders.
    @ObservationIgnored private weak var textView: NSTextView?

    var label: String { TextSearch.label(index: index, result: result) }

    /// Called by the editor once its text view exists.
    func attach(_ textView: NSTextView) { self.textView = textView }

    func show() {
        guard !isVisible else { return }
        anchor = textView?.selectedRange().location ?? 0
        isVisible = true
    }

    /// Clears synchronously: waiting for the debounced refresh would leave highlights on screen after
    /// the bar has gone. Focus goes back to the editor, where the caret sits on the last match found.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        result = .none
        index = 0
        revealedFor = nil
        clearHighlight()
        if let textView { textView.window?.makeFirstResponder(textView) }
    }

    /// ⌘E: search for the selection, the standard macOS "Use Selection for Find".
    func useSelectionAsQuery() {
        guard let textView else { return }
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return show() }
        query = (textView.string as NSString).substring(with: selection)
        anchor = selection.location
        isVisible = true
    }

    func step(by delta: Int) {
        // ⌘G with the bar closed reopens it on the last query rather than doing nothing.
        guard isVisible else { return show() }
        guard !result.isEmpty else { return }
        index = TextSearch.step(from: index, by: delta, count: result.count)
        anchor = result.ranges[index].location
        reveal(moveSelection: true)
    }

    /// Debounced recompute, run from `.task(id:)` so a newer request cancels this one. 200ms matches
    /// the body's JSON validation: highlighting is advisory and may lag, and a megabyte of JSON must
    /// not be rescanned per keystroke.
    func refresh(in text: String) async {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        guard isVisible, !query.isEmpty else {
            result = .none
            index = 0
            revealedFor = nil
            clearHighlight()
            return
        }
        let query = self.query
        let caseSensitive = self.caseSensitive
        // Off the main actor: the scan is linear in the body and the sheet stays responsive.
        let computed = await Task.detached(priority: .userInitiated) {
            TextSearch.matches(in: text, query: query, caseSensitive: caseSensitive)
        }.value
        guard !Task.isCancelled else { return }

        let queryChanged = revealedFor.map { $0.query != query || $0.caseSensitive != caseSensitive } ?? true
        if !queryChanged, let textView {
            // Only the body moved: follow the caret, so ⌘G continues from where the user is editing.
            anchor = textView.selectedRange().location
        }
        result = computed
        index = TextSearch.index(in: computed, atOrAfter: anchor)
        revealedFor = (query, caseSensitive)
        reveal(moveSelection: queryChanged)
    }

    // MARK: - Painting

    /// Highlights every match and marks the current one. With `moveSelection` it also selects that
    /// match and scrolls to it, so closing the bar leaves the caret on what was found.
    private func reveal(moveSelection: Bool) {
        guard let textView, !result.isEmpty else { return clearHighlight() }
        // Format rewrites the whole body, so a result can outlive the text it was computed from.
        // Ranges ascend, so dropping the out-of-bounds tail keeps `index` meaningful.
        let length = (textView.string as NSString).length
        let ranges = result.ranges.filter { NSMaxRange($0) <= length }
        guard index < ranges.count else { return clearHighlight() }

        let current = ranges[index]
        paint(ranges, current: current, in: textView)
        guard moveSelection else { return }
        textView.setSelectedRange(current)
        textView.scrollRangeToVisible(current)
        textView.showFindIndicator(for: current)
    }

    /// Temporary attributes rather than text attributes: they never enter the text storage, so they
    /// can't fire `textDidChange`, mark the body edited, or land on the undo stack. They need TextKit 1,
    /// which `PlainCodeEditor` builds explicitly.
    private func paint(_ ranges: [NSRange], current: NSRange, in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        removeTemporaryAttributes(from: layoutManager, in: textView)
        for range in ranges {
            layoutManager.addTemporaryAttributes([.backgroundColor: Self.match], forCharacterRange: range)
        }
        layoutManager.addTemporaryAttributes([.backgroundColor: Self.currentMatch,
                                              .foregroundColor: Self.currentMatchContent],
                                             forCharacterRange: current)
    }

    func clearHighlight() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        removeTemporaryAttributes(from: layoutManager, in: textView)
    }

    private func removeTemporaryAttributes(from layoutManager: NSLayoutManager, in textView: NSTextView) {
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
    }

    private static let match = NSColor(LemonadeTheme.colors.background.bgCautionSubtle)
    private static let currentMatch = NSColor(LemonadeTheme.colors.background.bgBrand)
    private static let currentMatchContent = NSColor(LemonadeTheme.colors.content.contentOnBrandHigh)

    /// Everything a search depends on, so `.task(id:)` restarts the debounce when any of it moves —
    /// the body included, because Format rewrites it under an open bar.
    struct Request: Equatable {
        let text: String
        let query: String
        let caseSensitive: Bool
        let isVisible: Bool
    }

    func request(for text: String) -> Request {
        Request(text: text, query: query, caseSensitive: caseSensitive, isVisible: isVisible)
    }
}

/// The find bar, docked above the editor. It used to float over the editor's corner to spare a 140pt
/// box; floating meant drawing over the code, and every way of doing that either hid the lines being
/// searched (opaque) or let them show through the bar's own controls (translucent). The editor now
/// has the full height of the sheet, so a row costs it little.
struct CodeEditorFindBar: View {
    @Bindable var find: CodeEditorFind

    /// Lemonade's `SearchField` owns the real `@FocusState` and mirrors it here; writing `true`
    /// focuses the field.
    @State private var fieldFocused = false

    var body: some View {
        HStack(spacing: LemonadeTheme.spaces.spacing200) {
            LemonadeUi.SearchField(
                input: $find.query,
                placeholder: "Find in body",
                onInputClear: { find.query = "" },
                // The bar has its own close button; a second dismissal inside the field would be
                // two controls doing slightly different things.
                dismissible: false,
                isFocused: $fieldFocused
            )
            .frame(maxWidth: 260)

            LemonadeUi.Chip(label: "Aa", selected: find.caseSensitive,
                            onChipClicked: { find.caseSensitive.toggle() })
                .help("Match case")

            if !find.query.isEmpty {
                LemonadeUi.Text(find.label,
                                textStyle: LemonadeTypography.shared.bodyXSmallRegular,
                                color: find.result.isEmpty
                                    ? LemonadeTheme.colors.content.contentCaution
                                    : LemonadeTheme.colors.content.contentTertiary,
                                maxLines: 1)
                    // Fixed width so "9 of 17" becoming "10 of 17" doesn't shove the buttons.
                    .frame(width: 76, alignment: .leading)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            LemonadeUi.IconButton(icon: .chevronTop, contentDescription: "Previous match",
                                  onClick: { find.step(by: -1) },
                                  enabled: !find.result.isEmpty, size: .small)
                .help("Previous match (⇧⌘G)")
            LemonadeUi.IconButton(icon: .chevronDown, contentDescription: "Next match",
                                  onClick: { find.step(by: 1) },
                                  enabled: !find.result.isEmpty, size: .small)
                .help("Next match (⌘G)")
            LemonadeUi.IconButton(icon: .times, contentDescription: "Close find",
                                  onClick: { find.hide() }, size: .small)
                .help("Close (Esc)")
        }
        // `.task` rather than `.onAppear`, so the field exists before focus is written to it. ⌘F
        // should put the caret in the field, not just draw the bar.
        .task { fieldFocused = true }
        .onSubmit { find.step(by: 1) }
        // Esc closes the bar. Focus can be anywhere in the sheet, so the sheet also catches it (see
        // `OverrideEditorSheet.findShortcuts`); stopping a search must never cost the whole draft.
        .onExitCommand { find.hide() }
        .animation(.easeInOut(duration: 0.15), value: find.query.isEmpty)
    }
}
