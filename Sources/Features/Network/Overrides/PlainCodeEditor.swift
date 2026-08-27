import SwiftUI
import AppKit
import Lemonade

/// A plain-text editor for content that must survive verbatim — JSON bodies in particular.
///
/// SwiftUI's `TextEditor` inherits AppKit's automatic substitutions, so typing `"` yields `“` and
/// `--` an em dash, silently invalidating a body. No modifier turns those off, so this is an
/// `NSTextView` with every substitution disabled — as `SqlEditorView` does for SQL.
struct PlainCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 11

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
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
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        context.coordinator.textView = textView

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView, textView.string != text else { return }
        // External change (the Format button): keep the caret in range so it doesn't jump.
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
