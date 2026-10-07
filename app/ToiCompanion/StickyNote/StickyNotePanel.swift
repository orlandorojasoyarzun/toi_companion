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
        // Never activate or become key — override the properties.
        ignoresMouseEvents = true

        // Float above everything except fullscreen exclusive windows.
        level      = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Semi-transparent so the background shows through.
        backgroundColor = .clear
        isOpaque        = false
        hasShadow       = false   // DOS has no shadows

        logger.info("StickyNotePanel configured")
    }

    private func configureContent() {
        // Wrap SwiftUI view in NSHostingView.
        let hostingView = NSHostingView(rootView: StickyNoteView(viewModel: viewModel))
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
        hideTimer = Timer.scheduledTimer(withTimeInterval: stayDuration, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
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
    private func resizeToFit() {
        guard let contentView = contentView,
              let hostingView = contentView.subviews.first as? NSHostingView<StickyNoteView> else { return }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        guard fittingSize.width > 0, fittingSize.height > 0 else { return }

        let bottomY = frame.origin.y
        let originX = frame.origin.x
        let newWidth  = max(260, fittingSize.width)
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
        }
    }
}

