import SwiftUI
import AppKit

/// `NSViewRepresentable` wrapping an `NSTextView` so the sticky note can
/// be edited in place. We use AppKit (not SwiftUI's `TextField`) for two
/// reasons:
///
///   1. `lineSpacing` actually applies per-line on `NSTextView`. SwiftUI's
///      `.lineSpacing(_:)` modifier is *ignored* when the text wraps onto
///      multiple lines inside an editable field, which broke the user's
///      Phase 7 settings ("clic pierde el formato del espaciado de línea").
///
///   2. We need full NSTextView features (selection, copy/paste, IME) so
///      editing feels like a normal text field.
///
/// The view uses a scrollable text view with a fixed width (matches the
/// panel) and unlimited height — the text view reports its own intrinsic
/// size and the host SwiftUI view wraps that.
struct WrappedTextField: NSViewRepresentable {

    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var lineSpacing: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Scroll view is what NSTextView lives inside. We use the
        // standard factory that gives us sensible defaults
        // (vertical scroller, borderless, etc.).
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Configure the text view itself.
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isSelectable = true
        textView.isEditable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0

        // Layout: width tracks the text view; container is as wide as
        // the text view and as tall as the content.
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)

        // Apply visual style.
        applyStyle(to: textView)

        // Initial text.
        textView.string = text
        textView.font = font
        textView.textColor = textColor

        // Hand the coordinator a reference so updateNSView can re-apply
        // style without rebuilding the view.
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator

        // Only replace the buffer when the SwiftUI binding and the
        // NSTextView disagree — i.e. when the change came from outside
        // the text view (e.g. the LLM stream). User typing in the
        // textView already mutated the binding via the delegate, so the
        // two stay in sync and this is a no-op.
        if textView.string != text {
            // Preserve the current selection across the update by
            // re-locating it inside the new string when possible.
            let sel = textView.selectedRange()
            let prior = textView.string as NSString
            let newString = text as NSString
            let safeLocation = min(sel.location, newString.length)
            let safeLength = min(sel.length, max(0, newString.length - safeLocation))
            textView.string = text
            textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))

            // Sanity: if the binding was set to something nonsensical
            // (e.g. truncated mid-UTF8 sequence), make sure we never
            // crash the text view. This shouldn't happen in practice
            // but is cheap insurance.
            _ = prior  // silence unused
        }

        // Always re-apply style so SettingsStore changes are live.
        textView.font = font
        textView.textColor = textColor

        // lineSpacing lives on a paragraph-style attribute, not the
        // text view directly. Re-apply to the whole string.
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.alignment = .left
        textView.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)

        // After any change, schedule a focus retry. The first attempt
        // usually works (the text view was just created with focus), but
        // if the user has been clicking around the panel we sometimes
        // need a second attempt on the next runloop tick.
        if coordinator.shouldRefocus {
            coordinator.shouldRefocus = false
            DispatchQueue.main.async { [weak textView] in
                guard let tv = textView, let win = tv.window else { return }
                win.makeFirstResponder(tv)
            }
        }
    }

    private func applyStyle(to textView: NSTextView) {
        textView.font = font
        textView.textColor = textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WrappedTextField
        weak var textView: NSTextView?

        /// Set by the SwiftUI view when the user just toggled edit mode on,
        /// so updateNSView knows to re-focus on the next runloop tick.
        var shouldRefocus: Bool = false

        init(_ parent: WrappedTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newText = tv.string
            if parent.text != newText {
                parent.text = newText
            }
        }
    }
}
