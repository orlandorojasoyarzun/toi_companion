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
            onClose: { [weak self] in self?.hide() }
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

        // The panel itself has no background — the visual effect view provides the blur.
        contentView = blurView
    }

    // MARK: - Public API

    /// Shows the sticky note at the cursor position with an optional initial text.
    func show(initialText: String = "...") {
        // Cancel any pending hide.
        hideTimer?.invalidate()
        hideTimer = nil

        // Reposition near cursor.
        let origin = cursorPositioner.computeOrigin()
        setFrameOrigin(NSPoint(x: origin.x, y: origin.y))

        // Fade in.
        alphaValue = 0
        orderFront(nil)
        viewModel.show(initialText: initialText)
        // Size the panel to fit the initial text. SwiftUI needs a runloop
        // to re-render after the @Published change, so we force a layout
        // pass before measuring.
        resizeToFit()

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
/// Anchors the bottom edge (near the cursor) and grows upward, with
/// clamping against the screen's visible frame so the panel never
/// extends off the top of the screen.
///
/// Phase 7.4: an `invalidateIntrinsicContentSize()` call before
/// `layoutSubtreeIfNeeded()` forces NSHostingView to recompute its
/// cached size. Without it, the host can return a stale `fittingSize`
/// during a fast LLM stream — the SwiftUI tree has updated, but the
/// hosting view's cached intrinsic content size is still from the
/// previous text, so the panel appears to "stop growing" mid-stream.
///
/// Phase 7.5: if the user has dragged the resize grip and we have a
/// `userSize` override, honour it instead of the natural content size.
/// Otherwise use the natural size as before.
private func resizeToFit() {
    guard let contentView = contentView,
          let hostingView = contentView.subviews.first as? NSHostingView<StickyNoteView> else { return }

    // Save the current panel size back into the view model so the
    // resize grip can read it on the next drag. Do this before
    // potentially calling setFrame so the grip always knows the size
    // we ended up with.
    viewModel.currentPanelSize = frame.size

    // If the user resized the panel, don't override their size.
    if viewModel.userSize != nil { return }

    hostingView.invalidateIntrinsicContentSize()
    hostingView.layoutSubtreeIfNeeded()
    let fittingSize = hostingView.fittingSize
    guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let bottomY = frame.origin.y
        let originX = frame.origin.x
        // Floor width at 280 to match StickyNoteView's `minPanelWidth`.
        // The view itself caps at 520, so we just honour whatever it
        // asks for above 280.
        let newWidth  = max(280, fittingSize.width)
        var newHeight = max(minPanelHeight, fittingSize.height)

        // Clamp: don't let the top of the panel go above the visible screen
        // (i.e. under the menu bar). If it would, cap the height.
        if let screen = self.screen ?? NSScreen.main {
            let maxTopY = screen.visibleFrame.maxY - edgeMargin
            if bottomY + newHeight > maxTopY {
                newHeight = max(minPanelHeight, maxTopY - bottomY)
            }
        }

        let newFrame = NSRect(x: originX, y: bottomY, width: newWidth, height: newHeight)
        if newFrame.size != frame.size {
            setFrame(newFrame, display: true, animate: false)
            viewModel.currentPanelSize = newFrame.size
        }
    }
}

