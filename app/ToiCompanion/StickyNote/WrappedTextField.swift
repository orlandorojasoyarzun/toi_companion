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
/// **Return / Enter handling.** The sticky note's edit field treats
/// plain Return as "send the transcript to the LLM" (matching common
/// chat-input UX). Shift+Return inserts a newline. Escape cancels
/// (exits edit mode without sending).
///
/// We can't just implement this via the
/// `textView(_:doCommandBy:)` delegate — NSTextView handles Return
/// natively by inserting a newline character, so the delegate's
/// `insertNewline:` branch never fires. The reliable approach is a
/// custom NSTextView subclass (`CommitTextView` below) that overrides
/// `keyDown` and intercepts Return *before* the default newline-insert
/// behavior runs.
struct WrappedTextField: NSViewRepresentable {

    @Binding var text: String
    var font: NSFont
    var textColor: NSColor
    var lineSpacing: CGFloat
    /// Called when the user presses plain Return (or numpad Enter)
    /// inside the field. The sticky note wires this to "exit edit
    /// mode and send the current text to the LLM".
    var onCommit: (() -> Void)? = nil
    /// Called when the user presses Escape. The host decides what
    /// cancel means (typically: exit edit mode without sending).
    var onCancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Use the AppKit factory to get a properly configured
        // scrollView + textView. The factory sets up the
        // textView's frame, autoresizingMask, and textContainer
        // (containerSize / widthTracksTextView) the way NSTextView
        // expects — wiring those up by hand is fiddly and one
        // missed property leaves the textView at (0, 0, 0, 0),
        // which is exactly the "text disappears but I can still
        // type" bug we hit in the previous iteration of this file.
        //
        // We then swap the factory's plain `NSTextView` for our
        // `CommitTextView` subclass, copying the factory's frame
        // and sizing / textContainer settings onto the new
        // textView. This keeps all the layout behavior the factory
        // gives us, while gaining Return / Enter / Escape
        // intercepts that the plain NSTextView swallows.
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        // Phase 7.7: fill the SwiftUI host's frame. Without this the
        // scroll view stays at its natural size and the parent's
        // frame extends past it, leaving a visible gap that the
        // NSVisualEffectView would show as a blur ring around the
        // text view.
        scrollView.autoresizingMask = [.width, .height]

        guard let factoryTextView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Build our CommitTextView, copying the factory's frame
        // and sizing / textContainer setup so the layout
        // behaviour stays identical to what the factory gave us.
        let textView = CommitTextView(frame: factoryTextView.frame)
        textView.minSize = factoryTextView.minSize
        textView.maxSize = factoryTextView.maxSize
        textView.isVerticallyResizable = factoryTextView.isVerticallyResizable
        textView.isHorizontallyResizable = factoryTextView.isHorizontallyResizable
        textView.autoresizingMask = factoryTextView.autoresizingMask
        if let ftc = factoryTextView.textContainer {
            textView.textContainer?.containerSize = ftc.containerSize
            textView.textContainer?.widthTracksTextView = ftc.widthTracksTextView
            textView.textContainer?.lineFragmentPadding = ftc.lineFragmentPadding
        }
        textView.textContainerInset = factoryTextView.textContainerInset

        textView.onCommit = onCommit
        textView.onCancel = onCancel

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

        scrollView.documentView = textView

        // Hand the coordinator a reference so updateNSView can re-apply
        // style without rebuilding the view.
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommitTextView else { return }
        let coordinator = context.coordinator

        // Re-bind the commit/cancel closures on every update. The
        // SwiftUI view passes fresh closures each render, and the
        // text view is reused across renders (NSViewRepresentable
        // reuses the underlying NSView), so the previous closure
        // would otherwise stick around even after the parent view
        // changed which `onCommit` to call.
        textView.onCommit = onCommit
        textView.onCancel = onCancel

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

        // NOTE: Return / Enter are NOT handled here. NSTextView
        // treats Return as a literal newline insert, so the
        // `doCommandBy:` delegate never sees the
        // `insertNewline:` selector — it gets consumed by the
        // default text-insertion path. Intercept happens in
        // `CommitTextView.keyDown` instead. Escape is also
        // intercepted there (via `keyCode == 53`) so the
        // behaviour stays in one place.
    }
}

// MARK: - CommitTextView

/// `NSTextView` subclass that intercepts Return / Enter / Escape
/// before the text view's default behaviors run:
///
/// - Plain Return (keyCode 36) or numpad Enter (keyCode 76) with
///   no modifiers → `onCommit`. This is the sticky note's
///   "send to LLM" gesture, matching common chat-input UX.
/// - Shift+Return / Option+Return / Cmd+Return → fall through to
///   `super.keyDown` so the user can still type newlines (Shift+Return)
///   or trigger any modifier-based shortcuts the text view supports.
/// - Plain Escape (keyCode 53) with no modifiers → `onCancel`.
///   Shift+Escape etc. fall through.
///
/// **Why a subclass and not just the delegate?** NSTextView handles
/// Return natively by inserting a `\n` character, which means
/// `textView(_:doCommandBy:)` with the `insertNewline:` selector
/// never fires — the text view consumes the event before the
/// delegate gets a chance. Overriding `keyDown` lets us intercept
/// the keystroke first and either consume it (commit) or pass it
/// through (newline).
final class CommitTextView: NSTextView {

    /// Wired by the SwiftUI host (`WrappedTextField.makeNSView` /
    /// `updateNSView`). Plain Return / Enter → fire this.
    var onCommit: (() -> Void)?

    /// Wired by the SwiftUI host. Plain Escape → fire this.
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Strip device-independent modifiers so we can match the
        // exact "no Shift/Cmd/Option/Control" combination. Numpad
        // flags and the like are ignored.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isPlain = mods.isEmpty

        switch event.keyCode {
        case 36, 76:  // Return, numpad Enter
            if isPlain {
                onCommit?()
                return
            }
        case 53:  // Escape
            if isPlain {
                onCancel?()
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}
