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

    /// Never becomes key — does not steal focus from the target app.
    override var canBecomeKey: Bool { false }
    /// Never becomes main — does not activate the app.
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

        // Add blur parent via NSVisualEffectView (stable across macOS versions).
        let blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: hostingView.fittingSize))
        blurView.autoresizingMask = [.width, .height]
        blurView.blendingMode   = .behindWindow
        blurView.material       = .popover
        blurView.state          = .active
        blurView.wantsLayer     = true
        // DOS has sharp corners — no rounding, no clipping.
        blurView.layer?.cornerRadius = 0
        blurView.layer?.masksToBounds = true

        blurView.addSubview(hostingView)

        // Force the visual effect view to redraw its layer on every
        // needsDisplay instead of caching a snapshot. Without this,
        // fast panel resizes (via the bottom-right grip) leave a
        // visible "ghost" of the previous frame because the cached
        // layer contents don't keep up with the new bounds.
        blurView.layerContentsRedrawPolicy = .onSetNeedsDisplay

        // The panel itself has no background — the visual effect view provides the blur.
        contentView = blurView
    }

    // MARK: - Public API

    /// Shows the sticky note at the cursor position with an optional initial text.
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

        // Reposition near cursor.
        let origin = cursorPositioner.computeOrigin()
        setFrameOrigin(NSPoint(x: origin.x, y: origin.y))

        // Fade in.
        alphaValue = 0
        orderFront(nil)
        viewModel.show(initialText: initialText)
        // Phase 7.7: no resize on show. The panel's size is set in
        // `init()` (greeting size) and only changes when the user
        // drags the grip. LLM responses scroll inside the
        // ScrollView instead of growing the panel. Calling
        // `resizeToFit()` here would re-fit the panel on every
        // show (the "re-arrange" glitch the user reported) and
        // also leave a brief window where the NSVisualEffectView
        // shows a stale blur of the old frame — the gray trail
        // behind the note.

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
        }
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
    guard let hostingView = contentView?.subviews.first as? NSHostingView<StickyNoteView> else { return }

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
