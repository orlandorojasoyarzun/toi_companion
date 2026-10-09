import AppKit
import SwiftUI
import os.log

/// The floating panel that hosts the sticky note.
/// - Non-activating: does not steal focus from the target app.
/// - Ignores mouse events: clicks pass through to the app underneath.
/// - Floating level: always on top of normal windows.
/// - Can join all spaces: appears on every desktop.
final class StickyNotePanel: NSPanel {

    private let logger = Logger(subsystem: "com.salem.toicompanion", category: "StickyNotePanel")
    private let viewModel = StickyNoteViewModel()
    private let cursorPositioner = CursorPositioner()

    // MARK: - Panel behavior overrides

    /// Becomes key only while the user is editing the transcript.
    /// The default `false` keeps the panel from stealing focus
    /// during listening / streaming / response display, but
    /// flipping to `true` when `isEditing` is on lets the
    /// `NSTextView` inside the `WrappedTextField` actually
    /// receive first responder — without this, the ↲ button
    /// shows the field but no keystrokes land in it.
    override var canBecomeKey: Bool { viewModel.isEditing }
    /// Never becomes main — does not activate the app. We rely
    /// on `NSApp.activate(ignoringOtherApps:)` being called
    /// explicitly in `beginEditMode()` and `toggleEdit()`
    /// instead, so the menu bar only updates when we actually
    /// want it to.
    override var canBecomeMain: Bool { false }

    // MARK: - Animation constants

    private let fadeInDuration: TimeInterval  = 0.20
    private let fadeOutDuration: TimeInterval = 0.40
    private let stayDuration:     TimeInterval = 2.00  // Phase 5+: after stream ends
    private let edgeMargin:       CGFloat     = 20
    /// Floor for the panel's height. Matches the original Phase 1 size:
    /// enough for the header + ~4 lines of text so the panel reads as
    /// "an empty note" before the user starts talking. When the transcript
    /// exceeds this, the panel keeps growing upward.
    private let minPanelHeight:   CGFloat     = 140

    private var hideTimer: Timer?

    // MARK: - Shared instance

    static let shared = StickyNotePanel()

    /// Set by the AppDelegate to receive "send the current text to
    /// the LLM" requests from the sticky note's Enter key or ✓
    /// button. The closure receives the panel's current
    /// `viewModel.text` at the moment of the send. nil = no-op
    /// (the panel still works, just no send happens).
    var onSendRequested: ((String) -> Void)? = nil

    // MARK: - Init

    private init() {
        let positioner = CursorPositioner()
        let origin = positioner.computeOrigin()
        let frame = NSRect(
            x: origin.x,
            y: origin.y,
            width: positioner.panelWidth,
            height: positioner.panelHeight
        )

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configurePanel()
        configureContent()
    }

    private func configurePanel() {
        // Accept mouse events so the user can dismiss the panel with a
        // click (see mouseDown below). canBecomeKey/Main stay false so
        // the click doesn't steal focus from the app underneath.
        ignoresMouseEvents = false

        // Float above everything except fullscreen exclusive windows.
        level      = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Semi-transparent so the background shows through.
        backgroundColor = .clear
        isOpaque        = false
        hasShadow       = false   // DOS has no shadows

        logger.info("StickyNotePanel configured")
    }

    /// Click anywhere on the panel to dismiss it. Used by `stayUntilClick`
    /// for terminal states (LLM response, error) where the message should
    /// linger until the user is ready to move on. Clicks during the
    /// listening/streaming phases still dismiss — the LLM task that was
    /// writing to the panel is cancelled on the next PTT press anyway.
    ///
    /// Phase 7.2: a click in the top bar is treated as a window-drag
    /// gesture so the user can grab the note and move it. The X button
    /// in the bar calls `hide()` directly through the SwiftUI `onClose`
    /// closure.
/// Phase 7.3: body clicks no longer close the panel. Only the X does,
/// so the user can read an LLM answer without accidentally dismissing
/// it by clicking on the note while looking at it.
    override func mouseDown(with event: NSEvent) {
        let inTopBar = event.locationInWindow.y >= frame.height - StickyNoteView.topBarHeight
        if inTopBar {
            // Hand off to AppKit's window-drag machinery. SwiftUI's X
            // button consumes mouseDowns inside its frame, so a click
            // that reaches us here is always in the drag-grip area.
            // `performDrag` is an NSWindow method; NSPanel inherits it,
            // so we call it on self directly without going through
            // `self.window?` (the latter doesn't resolve in this scope).
            performDrag(with: event)
            return
        }
        // Body click — deliberately a no-op. See Phase 7.3 above.
    }

    private func configureContent() {
        // Wrap SwiftUI view in NSHostingView. `onClose` is the X button
        // in the top bar — wired to `hide()` so the panel actually
        // dismisses when the user clicks ×.
        let hostingView = NSHostingView(rootView: StickyNoteView(
            viewModel: viewModel,
            onClose: { [weak self] in self?.hide() },
            onSend: { [weak self] in
                guard let self = self else { return }
                self.onSendRequested?(self.viewModel.text)
            }
        ))
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.autoresizingMask = [.width, .height]

        // Phase 7.8.2: the panel IS the sticky note — no
        // NSVisualEffectView blur, no gray popover border, no
        // `behindWindow` blending. The SwiftUI body's own
        // `settings.theme.background` fill (on topBar / content /
        // bottomGrip) provides the panel's appearance edge-to-edge.
        //
        // The earlier NSVisualEffectView(.popover) was the source
        // of the "borde gris blur" the user kept seeing — when the
        // panel's frame was set but the contentView's autoresizing
        // hadn't caught up (or the hostingView's intrinsic content
        // size was stale), the blur view extended past the SwiftUI
        // body and the visible "leftover" area was a translucent
        // gray rectangle. Removing the blur view entirely kills
        // that class of glitch — the panel is now exactly the
        // SwiftUI body, nothing more.
        contentView = hostingView
    }

    // MARK: - Public API

    /// Optional closure that returns the menu bar status icon's
    /// current frame in screen coordinates. Set by AppDelegate after
    /// the MenuBarController is created. When set, every `show()`
    /// anchors the panel just below the icon (its visual "home
    /// base"). When nil, falls back to the cursor — useful for the
    /// first few milliseconds of launch before the AppDelegate wires
    /// things up.
    ///
    /// Why a closure and not a direct reference to the status item?
    /// The icon's frame changes if the user opens the system menu
    /// bar extras editor, or if the screen's status bar layout
    /// reflows when other apps install status items. Reading the
    /// frame on each `show()` keeps us current without subscribing
    /// to layout notifications.
    var menuBarFrameProvider: (() -> NSRect?)?

    /// Shows the sticky note. By default the panel anchors **just
    /// below the menu bar icon** (so the note always reappears in
    /// the same predictable spot, even after the user dragged it
    /// somewhere else and closed it). The drag-grip and top-bar
    /// drag gesture still work, so the user can move it freely
    /// within a session — the next `show()` simply resets it to
    /// the default.
    func show(initialText: String = "...") {
        // Cancel any pending hide.
        hideTimer?.invalidate()
        hideTimer = nil

        // Phase 7.8: reset the user-resize override so the panel
        // always starts at the default "listening" size, even if
        // the user dragged the grip on a previous show. The grip
        // still works *within* a single show — this just clears
        // the carryover between shows.
        viewModel.userSize = nil

        // Phase 7.8.2: set the text FIRST so the SwiftUI body has
        // the new text in its view tree before we resize. The
        // `@Published` assignment is synchronous, so by the time
        // `setFrame` runs the body's `text` is "Listening ..." —
        // even though the layer won't re-render until the next
        // runloop tick, the `fittingSize` we read afterwards
        // (if any) would already reflect the new content.
        viewModel.show(initialText: initialText)

        // Phase 7.8.1 (revisited): set the panel to the default
        // size at the new origin *before* `orderFront`. This is
        // the only way to guarantee the panel doesn't show up at
        // the old 340×500 size from the previous LLM stream.
        //
        // Why not `resizeToFit()`? Because it reads
        // `hostingView.fittingSize`, which is async — the
        // NSHostingView's cached intrinsic content size is still
        // from the previous stream at this point, so
        // `resizeToFit()` would happily keep the panel at 500pt.
        // The panel only snaps back to 140 when the first
        // `updateText` from the STT triggers a second
        // `resizeToFit` on the next runloop tick (the
        // "se reecuadra" glitch).
        //
        // Why not `setFrame` alone? Earlier attempts with
        // `display: false` and the old NSVisualEffectView caused
        // the blur view to stay at the old size. Now the
        // contentView IS the hostingView directly, so
        // `setFrame` resizes the panel AND the contentView in one
        // go (autoresizingMask cascade on the hostingView), and
        // `display: true` forces the layer to commit.
        //
        // Anchor: prefer the menu bar icon's position (set via
        // `menuBarFrameProvider` by AppDelegate) so every show
        // reappears just below the icon — predictable spot, easy
        // to find. Fall back to the cursor if the provider isn't
        // wired yet (very early launch) or returns a degenerate
        // frame.
        let origin: CursorPositioner.Position
        if let frame = menuBarFrameProvider?(),
           frame.width > 0, frame.height > 0 {
            origin = cursorPositioner.computeOriginBelowMenuBar(statusItemFrame: frame)
        } else {
            origin = cursorPositioner.computeOrigin()
        }
        let defaultFrame = NSRect(
            x: origin.x,
            y: origin.y,
            width: cursorPositioner.panelWidth,
            height: cursorPositioner.panelHeight
        )
        // Phase 7.8.3: force the panel through a hide → resize →
        // show cycle. When the panel is already visible (e.g. the
        // user presses shift while the note from the previous LLM
        // response is still on screen), `setFrame` alone updates
        // the window's frame but the contentView's autoresizingMask
        // cascade is deferred to the next runloop tick — the panel
        // shows up at the old 340×500 size and only snaps to 140
        // when the first `updateText` triggers another
        // `resizeToFit` (the "se reecuadra" glitch). Pulling the
        // panel out of the window hierarchy first with `orderOut`
        // ensures the resize is committed synchronously.
        //
        // `alphaValue = 0` is set *before* `orderOut` so the
        // panel is already invisible when we yank it from the
        // hierarchy — the user only sees the fade-in to the
        // new size, not a flash of the old one.
        alphaValue = 0
        orderOut(nil)
        setFrame(defaultFrame, display: true)
        // Explicitly resize the hostingView as well. The
        // contentView autoresizing cascade is supposed to handle
        // this, but in practice when the panel was just yanked
        // out of the window hierarchy the hostingView's frame
        // can lag the window's contentRect. Setting the frame
        // here keeps both in lockstep before we re-show.
        if let hostingView = contentView as? NSHostingView<StickyNoteView> {
            hostingView.frame = NSRect(origin: .zero, size: defaultFrame.size)
            hostingView.layoutSubtreeIfNeeded()
        }
        orderFront(nil)

        // Fade in. `alphaValue = 0` was already set above (before
        // `orderOut`) so the panel was invisible during the
        // hide/resize/show cycle. The fade-in here is what reveals
        // it at the new default size — the SwiftUI body has had
        // the runloop tick it needed to re-render with
        // "Listening ...".
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeInDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1.0
        }

        logger.info("StickyNotePanel shown at (\(origin.x), \(origin.y))")
    }

    /// Hides the sticky note immediately with a fast fade.
    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10  // Fast fade — for cancellation during re-press
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.viewModel.hide()
        })
    }

    /// Enter edit mode after a PTT finalize, so the user can correct
    /// the transcript before sending. Mirrors the ↲ button's effect
    /// but doesn't require a click — the panel activates and the
    /// freshly-created NSTextView becomes first responder for
    /// immediate typing. The user then commits with Enter (or the
    /// ✓ button), or cancels with Escape.
    func beginEditMode() {
        viewModel.isEditing = true
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.makeKeyAndOrderFront(nil)
            // The SwiftUI body needs a runloop tick to swap from the
            // static `Text` to the `WrappedTextField` (which lazily
            // creates the NSTextView in `makeNSView`). One more async
            // hop waits for that re-render before we look for the
            // text view in the view hierarchy. Without this, the
            // first attempt finds nothing — the text view doesn't
            // exist yet — and the user has to click the field
            // manually to start typing.
            DispatchQueue.main.async {
                self.focusFirstTextView()
            }
        }
    }

    /// Walk the view hierarchy and make the first NSTextView the
    /// first responder. Called from `beginEditMode()` and from the
    /// ↲ button's flow in `StickyNoteView.toggleEdit()` so the
    /// user can type immediately after the panel flips to edit
    /// mode. Returns silently if no NSTextView is found yet (the
    /// SwiftUI body may still be mid-render — caller can retry
    /// from the next runloop tick).
    func focusFirstTextView() {
        guard let textView = findTextView(in: contentView) else { return }
        makeFirstResponder(textView)
    }

    /// Recursive first-NSTextView search. The NSTextView lives two
    /// levels deep (NSHostingView > NSScrollView > NSTextView) so a
    /// fixed-depth lookup would be brittle — walk the tree instead.
    private func findTextView(in view: NSView?) -> NSTextView? {
        guard let view = view else { return nil }
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) { return textView }
        }
        return nil
    }

    /// Mark the start/end of an LLM stream. The panel is fixed-size
    /// now (the SwiftUI view fills the frame and a long response
    /// scrolls inside the ScrollView), so this no longer drives
    /// any resize — the flag is kept for UI affordances and as a
    /// defensive gate inside `resizeToFit()`.
    func setIsStreaming(_ streaming: Bool) {
        viewModel.isStreaming = streaming
    }

    /// Schedules the sticky note to hide after `stayDuration` seconds,
    /// then fade out. Used at the end of a response cycle.
    func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = nil
        hideTimer = Timer.scheduledTimer(withTimeInterval: stayDuration, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    /// Keep the sticky note visible until the user clicks it. Cancels
    /// any pending auto-hide timer. Used for terminal states (LLM
    /// response, errors) where 2 seconds is too short to read.
    /// Click → `mouseDown` → `hide()` (fast fade).
    func stayUntilClick() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeOutDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.viewModel.hide()
        })
    }

    /// Updates the text displayed in the note. Safe to call from any thread.
    @MainActor
    func updateText(_ text: String) {
        viewModel.updateText(text)
        resizeToFit()
    }

    // MARK: - Layout

    /// Resizes the panel to fit the SwiftUI view's intrinsic content size.
/// Anchors the **top edge** and grows downward as the LLM response
/// streams in, so the user can see the text arriving instead of it
/// being hidden behind a scroll. Clamped to `maxAutoFitHeight` so a
/// runaway stream doesn't push the panel off the screen; beyond
/// the cap, the inner `ScrollView` takes over.
///
/// Phase 7.4: an `invalidateIntrinsicContentSize()` call before
/// `layoutSubtreeIfNeeded()` forces NSHostingView to recompute its
/// cached size. Without it, the host can return a stale `fittingSize`
/// during a fast LLM stream — the SwiftUI tree has updated, but the
/// hosting view's cached intrinsic content size is still from the
/// previous text, so the panel appears to "stop growing" mid-stream.
///
/// Phase 7.5: if the user has dragged the resize grip and we have a
/// `userSize` override, honour it instead of the natural content size
/// (no auto-fit, no auto-grow — the user owns the size from then on).
///
/// Phase 7.8: re-enabled the auto-grow behaviour. Phase 7.7 had made
/// this a no-op so the panel stayed at the greeting size and the
/// response scrolled inside the ScrollView. The user reported that
/// this hid the streaming text and didn't "invite" them to open the
/// note — they want the note to visibly grow as the LLM types.
private func resizeToFit() {
    // Phase 7.8.2: the hostingView IS the contentView now (no
    // more NSVisualEffectView wrapper), so cast directly instead
    // of going through `subviews.first`.
    guard let hostingView = contentView as? NSHostingView<StickyNoteView> else { return }

    // Save the current panel size back into the view model so the
    // resize grip can read it on the next drag.
    viewModel.currentPanelSize = frame.size

    // Phase 7.5: if the user has manually resized, respect their
    // size and stop auto-fitting. The drag-grip owns the size from
    // here on.
    if viewModel.userSize != nil {
        return
    }

    // Phase 7.4: force the hosting view to recompute its intrinsic
    // content size. Without this, the host can return a stale
    // `fittingSize` during a fast LLM stream.
    hostingView.invalidateIntrinsicContentSize()
    hostingView.layoutSubtreeIfNeeded()

    // Phase 7.8: grow downward (anchor top-left) up to a cap.
    // Beyond the cap the inner ScrollView handles the overflow.
    let fittingSize = hostingView.fittingSize
    let maxAutoFitHeight: CGFloat = 500
    let targetHeight = min(max(fittingSize.height, minPanelHeight), maxAutoFitHeight)

    // Anchor the top-left: push the origin down by the height
    // delta. Without this the panel would grow upward (away from
    // the cursor) — same inversion the resize-grip had before the
    // Phase 7.8 fix.
    var newFrame = frame
    let heightDelta = targetHeight - newFrame.size.height
    newFrame.size.height = targetHeight
    newFrame.origin.y -= heightDelta
    setFrame(newFrame, display: true)
}
}
