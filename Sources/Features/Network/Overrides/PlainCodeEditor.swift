import SwiftUI
import AppKit
import Lemonade

/// A plain-text editor for content that must survive verbatim — JSON bodies in particular.
///
/// SwiftUI's `TextEditor` inherits AppKit's automatic substitutions, so typing `"` yields `“` and
/// `--` an em dash, silently invalidating a body. No modifier turns those off, so this is an
/// `NSTextView` with every substitution disabled — as `SqlEditorView` does for SQL.
///
/// Pass a `CodeEditorFind` to get ⌘F / ⌘G / ⇧⌘G / ⌘E over the text.
struct PlainCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 11
    var find: CodeEditorFind?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // An explicit TextKit 1 stack. A bare `NSTextView()` gets TextKit 2, whose `layoutManager` is
        // nil until something forces a compatibility fallback, and the find highlights are layout
        // manager temporary attributes. Building it here makes that deterministic.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // Unbounded height (the scroll view handles overflow); the width tracks the view below.
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        // Without this, scrolling to a match near the end of a large body lays out all of it first.
        layoutManager.allowsNonContiguousLayout = true

        let textView = FindableTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 140),
                                        textContainer: container)
        textView.find = find
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor(LemonadeTheme.colors.content.contentPrimary)
        textView.insertionPointColor = NSColor(LemonadeTheme.colors.content.contentPrimary)
        textView.backgroundColor = NSColor(LemonadeTheme.colors.background.bgNeutralSubtle)

        // The point of this view: a body is literal bytes, never prose.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = text

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        container.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        context.coordinator.textView = textView
        find?.attach(textView)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView as? FindableTextView else { return }
        textView.find = find
        guard textView.string != text else { return }
        // External change (the Format button) replaces the whole body, so every highlighted range is
        // stale. Clear them against the old text before swapping; the debounced search repaints.
        find?.clearHighlight()
        // Keep the caret in range so it doesn't jump.
        let caret = min(textView.selectedRange().location, (text as NSString).length)
        textView.string = text
        textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: PlainCodeEditor
        weak var textView: NSTextView?
        init(_ parent: PlainCodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
        }
    }
}

/// Catches the find shortcuts.
///
/// `performKeyEquivalent(with:)` walks the key window's view hierarchy before anything receives
/// `keyDown`, so ⌘F works whether or not the editor has focus. Catching it on the view keeps it
/// scoped: no app-wide event monitor to tear down, and no Edit-menu item live in every other area.
///
/// ⌃F is deliberately left alone. AppKit's `StandardKeyBinding.dict` maps `^f` to `moveForward:`;
/// it is right-arrow in every macOS text view, and taking it inside an editor breaks cursor movement.
final class FindableTextView: NSTextView {
    var find: CodeEditorFind?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let find, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        // Only the modifiers that mean something here; caps lock and the function-key bits ride
        // along on real events and would break an equality test against the raw flags.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (key, flags) {
        case ("f", [.command]):         find.show()
        case ("g", [.command]):         find.step(by: 1)
        case ("g", [.command, .shift]): find.step(by: -1)
        case ("e", [.command]):         find.useSelectionAsQuery()
        default:                        return super.performKeyEquivalent(with: event)
        }
        return true
    }

    /// Esc is not a key equivalent, so with focus in the editor it arrives here. Closing the bar is
    /// the only thing it should do while the bar is open.
    override func cancelOperation(_ sender: Any?) {
        guard let find, find.isVisible else { return super.cancelOperation(sender) }
        find.hide()
    }
}
