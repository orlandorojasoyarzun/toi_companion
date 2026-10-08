import SwiftUI
import AppKit

/// SwiftUI view rendered inside the sticky note panel.
///
/// Phase 1: simple text with a pill-style indicator. Later adds streaming text.
/// Phase 7: font / size / line-spacing / theme are driven by
/// `SettingsStore.shared` so changes in the settings window apply
/// live without a relaunch.
/// Phase 7.1: panel grows horizontally *and* vertically as the text
/// gets longer, so a very long LLM response doesn't end up as a 30-line
/// tower. The growth is a smooth function of character count clamped
/// between `minPanelWidth` and `maxPanelWidth`; see `preferredWidth`.
/// Phase 7.2: small top bar with a drag-grip on the left and an `×`
/// close button on the right.
/// Phase 7.5: edit mode (click ↲ to type into the transcript, click
/// anywhere outside to commit), resize grip in the bottom-right corner,
/// X moved to top-left and ↲ (return) to top-right.
struct StickyNoteView: View {

    @ObservedObject var viewModel: StickyNoteViewModel
    @ObservedObject private var settings = SettingsStore.shared

    /// Called when the user taps the X in the top bar. Wired by the
    /// owning `StickyNotePanel` to `hide()`.
    var onClose: () -> Void = {}
    /// Called when the user commits the edit (Enter in the text
    /// view, or the ✓ button in the top bar). Wired by the owning
    /// `StickyNotePanel` to `AppDelegate.sendCurrentTranscript()`
    /// so the LLM stream starts.
    var onSend: () -> Void = {}

    private let cornerRadius: CGFloat = 0  // DOS has sharp corners
    private let padding: CGFloat = 12

    /// Panel width bounds. The actual width is a smooth function of the
    /// text length — see `preferredWidth` below — but it never goes
    /// outside this range.
    ///
    /// `minPanelWidth` is locked to `CursorPositioner.panelWidth` (340).
    /// If they're out of sync the SwiftUI body is wider than the NSPanel
    /// and the right edge of the content (including the ↲ button in the
    /// top bar) gets clipped by the panel's contentRect — the "buttons
    /// covered" bug.
    private let minPanelWidth: CGFloat = 340
    private let maxPanelWidth: CGFloat = 420
    /// Floor for the panel's height. Matches `StickyNotePanel.minPanelHeight`
    /// so an empty / very-short note still reads as a deliberate note.
    private let minPanelHeight: CGFloat = 140

    /// Height of the top control bar. Kept in sync with the parent's
    /// `mouseDown` check so clicks in this band start a window drag
    /// instead of a close.
    ///
    /// Phase 7.8: bumped from 20 → 24 so the 22-pt-wide X / ↲ buttons
    /// read as "almost square" instead of "wide rectangles squished
    /// against the top edge". 24 makes the button frame 22×24 — the
    /// vertical padding inside the button now matches the horizontal
    /// padding (`padding(.leading, 10)` / `.trailing, 12)`), so the
    /// X and ↲ icons sit in the visual middle of the bar.
    static let topBarHeight: CGFloat = 24

    /// Height of the bottom resize grip strip.
    private let bottomGripHeight: CGFloat = 12

    /// Width matches the panel when the user hasn't dragged the grip.
    /// Phase 7.7+: the panel is fixed-size at the greeting — LLM
    /// responses scroll inside the `ScrollView` instead of growing
    /// the note. The previous text-driven growth formula made the
    /// SwiftUI body wider than the NSPanel, so the right edge of the
    /// content (including the ↲ button) got clipped by the
    /// `contentRect`. Honouring the user's manual resize keeps the
    /// drag-grip working.
    private var preferredWidth: CGFloat {
        if let userSize = viewModel.userSize {
            return max(minPanelWidth, min(maxPanelWidth, userSize.width))
        }
        return minPanelWidth
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
            bottomGrip
        }
        .frame(width: preferredWidth)
        // The VStack fills the panel's content area vertically. The
        // topBar and bottomGrip are fixed-height; the middle (content)
        // grows to fill the rest via its own `.frame(maxHeight: .infinity)`
        // so the resize-grip stays pinned to the bottom of the panel.
        .frame(minHeight: minPanelHeight, maxHeight: .infinity)
        // NOTE: do NOT add `.background(...)` here. In Phase 7.7 we
        // added a background on the VStack to keep the NSHostingView
        // opaque (kill the "gray trail" the NSVisualEffectView showed
        // through the gaps). That worked in isolation but combined
        // with `.frame(maxHeight: .infinity)` it makes SwiftUI pick
        // the View-overload of `.background()` and the "background"
        // reports an intrinsic size of infinity — the VStack then
        // grows to fill the screen, the hostingView's fittingSize
        // explodes, and the panel ends up covering the entire display.
        //
        // The children's own `.fill(settings.theme.background)`
        // backgrounds (in topBar, content's ZStack, and bottomGrip)
        // already cover the VStack edge-to-edge with no gaps because
        // the VStack uses `spacing: 0`. So the "gray trail" is gone
        // without needing a VStack-level background.
    }

    /// 20pt strip at the very top.
    /// Phase 7.5: X (close) is on the **left** now, ↲ (enter edit) on the
    /// **right**. The middle is empty / drag-friendly.
    private var topBar: some View {
        HStack(spacing: 0) {
            // X close button — top-LEFT (Phase 7.5). Sized 22×20. SwiftUI's
            // Button consumes the mouseDown so the parent's drag-handler
            // doesn't fire for this region.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(settings.theme.text.opacity(0.7))
                    .frame(width: 22, height: Self.topBarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Bumped from 6 → 10 so the X has a bit more breathing room
            // from the panel's left edge. At 260 pt the 6 pt padding put
            // the icon visually flush with the corner.
            .padding(.leading, 10)

            Spacer()

            // ↲ (return / enter edit mode) — top-RIGHT (Phase 7.5). When
            // tapped, flips `viewModel.isEditing` to true and the body
            // swaps from a static `Text` to a `WrappedTextField`. While
            // editing, this same button shows a "✓" (check) and tapping
            // it commits the edit (sets `isEditing` false again).
            Button(action: toggleEdit) {
                Image(systemName: viewModel.isEditing ? "checkmark" : "return")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(settings.theme.text.opacity(0.7))
                    .frame(width: 22, height: Self.topBarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Bumped from 8 → 12 (mirror of the X's 10) so both buttons
            // sit comfortably inside the panel.
            .padding(.trailing, 12)
        }
        .frame(height: Self.topBarHeight)
        .background(
            Rectangle()
                .fill(settings.theme.background)
        )
    }

    /// The body: filled background rectangle + VStack with the
    /// `>toi_companion` header and either the static text (normal mode)
    /// or an editable field (edit mode). Phase 7.5 added the
    /// edit-mode branch.
    private var content: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(settings.theme.background)

            VStack(alignment: .leading, spacing: 4) {
                // Optional caret/header line for that CRT feel.
                HStack(spacing: 4) {
                    Text(">")
                        .font(.system(size: settings.fontSize, weight: .bold, design: .monospaced))
                        .foregroundColor(settings.theme.text)
                    Text("toi_companion")
                        .font(.system(size: settings.fontSize - 1, weight: .regular, design: .monospaced))
                        .foregroundColor(settings.theme.text.opacity(settings.theme.headerOpacity))
                }

                if viewModel.isEditing {
                    // EDIT MODE (Phase 7.5).
                    // `WrappedTextField` is an NSViewRepresentable wrapping
                    // NSTextView, so we get real text-editing semantics
                    // (selection, copy/paste, cursor) AND can apply the
                    // settings.lineSpacing without SwiftUI's `lineSpacing`
                    // modifier (which doesn't work inside NSTextView).
                    WrappedTextField(
                        text: Binding(
                            get: { viewModel.text },
                            set: { viewModel.updateText($0) }
                        ),
                        font: NSFont(name: settings.fontFamily, size: settings.fontSize)
                            ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular),
                        textColor: NSColor(settings.theme.text),
                        lineSpacing: settings.fontSize * (settings.lineSpacing - 1.0),
                        onCommit: {
                            // Enter pressed — exit edit mode (async so
                            // the text view tears down before onSend
                            // fires and replaces the text) then hand
                            // off to the LLM stream runner.
                            DispatchQueue.main.async {
                                viewModel.isEditing = false
                                onSend()
                            }
                        },
                        onCancel: {
                            // Escape — exit edit mode, no send. The
                            // panel stays visible so the user can
                            // review or re-edit.
                            viewModel.isEditing = false
                        }
                    )
                    // EDIT MODE: the NSScrollView inside the
                    // NSViewRepresentable fills this frame (its
                    // autoresizingMask is `.width, .height`), so a
                    // long transcript scrolls inside the field
                    // instead of pushing the panel taller.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    // STATIC MODE. Phase 7.7: wrap the Text in a
                    // ScrollView so a long LLM response scrolls
                    // inside the panel instead of growing it. The
                    // Text keeps `fixedSize(horizontal: false,
                    // vertical: true)` so it reports its natural
                    // height and the ScrollView shows a vertical
                    // scroller once that exceeds the visible area.
                    // Tapping anywhere on the text enters edit mode
                    // so the user can correct the transcript without
                    // hunting for the ↲ button in the top bar.
                    ScrollView {
                        Text(viewModel.text.isEmpty ? "..." : viewModel.text)
                            .font(.custom(settings.fontFamily, size: settings.fontSize))
                            .foregroundColor(settings.theme.text)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(settings.fontSize * (settings.lineSpacing - 1.0))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleEdit()
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(padding)
            // Phase 7.7: make the inner VStack fill the ZStack so the
            // Rectangle background (and the ScrollView / text field)
            // extend to the panel's content edges, killing the gray
            // blurred ring the NSVisualEffectView was showing where
            // the SwiftUI view used to leave a gap.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 12pt strip at the very bottom. Houses the resize grip (Phase 7.5).
    /// `ResizeGripView` is an NSViewRepresentable that draws the classic
    /// diagonal lines and forwards mouseDown/Dragged to a callback that
    /// updates `viewModel.userSize` and re-frames the panel.
    private var bottomGrip: some View {
        ResizeGripView(
            currentSize: viewModel.currentPanelSize,
            minWidth: minPanelWidth,
            maxWidth: maxPanelWidth,
            minHeight: minPanelHeight,
            onResize: { newSize in
                viewModel.userSize = newSize
            }
        )
        .frame(height: bottomGripHeight)
        .background(
            Rectangle()
                .fill(settings.theme.background)
        )
    }

    // MARK: - Edit mode

    /// Flip the `isEditing` flag. When entering edit, force a window
    /// become-key so the NSTextView can actually receive text input —
    /// our NSPanel normally has `canBecomeKey == false` to avoid
    /// stealing focus, so we override that single time.
    private func toggleEdit() {
        if viewModel.isEditing {
            // ✓ clicked: exit edit mode. If there's text, send it
            // (the same path Enter takes).
            viewModel.isEditing = false
            if !viewModel.text.isEmpty {
                onSend()
            }
        } else {
            // ↲ clicked: enter edit mode + activate the panel so
            // the text view becomes first responder.
            viewModel.isEditing = true
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let panel = NSApp.windows.first(where: { $0 is StickyNotePanel }) as? StickyNotePanel {
                    panel.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}

// MARK: - Resize grip

/// Bottom-right resize grip. The visible part is just six short diagonal
/// strokes in the theme's text colour at 50% opacity. Mouse drag updates
/// the panel's frame via the `onResize` callback.
struct ResizeGripView: NSViewRepresentable {
    var currentSize: CGSize
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var minHeight: CGFloat
    var onResize: (CGSize) -> Void

    func makeNSView(context: Context) -> ResizeGripNSView {
        let v = ResizeGripNSView()
        v.onResize = onResize
        v.minWidth = minWidth
        v.maxWidth = maxWidth
        v.minHeight = minHeight
        return v
    }

    func updateNSView(_ nsView: ResizeGripNSView, context: Context) {
        nsView.onResize = onResize
        nsView.minWidth = minWidth
        nsView.maxWidth = maxWidth
        nsView.minHeight = minHeight
        nsView.needsDisplay = true
    }
}

/// NSView that draws the grip pattern and handles the drag gesture.
final class ResizeGripNSView: NSView {

    var onResize: ((CGSize) -> Void)?
    var minWidth: CGFloat = 280
    var maxWidth: CGFloat = 380
    var minHeight: CGFloat = 140

    private var dragStart: NSPoint = .zero
    private var startSize: NSSize = .zero

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw 3 short diagonal lines in the bottom-right corner.
        let lineColor = NSColor(white: 1.0, alpha: 0.4).cgColor
        let lineWidth: CGFloat = 1.0
        let length: CGFloat = 5.0
        let gap: CGFloat = 3.0
        let inset: CGFloat = 2.0

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(lineColor)
        ctx.setLineWidth(lineWidth)

        for i in 0..<3 {
            let x = bounds.width - inset - length - CGFloat(i) * gap
            let y = inset + CGFloat(i) * gap
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x + length, y: y + length))
            ctx.strokePath()
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        if let panel = window {
            startSize = panel.frame.size
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = window else { return }
        // Flipped coords (AppKit y-up). The grip is at the bottom-right
        // corner of the panel; we want the bottom-right corner to follow
        // the cursor.
        //   dx: drag *right* grows width — sign already correct.
        //   dy: drag *down* should grow height, but in AppKit the
        //       cursor's y *decreases* when going down — flip the sign
        //       so drag-down → positive dy → larger height.
        let dx = event.locationInWindow.x - dragStart.x
        let dy = dragStart.y - event.locationInWindow.y

        let newW = max(minWidth, min(maxWidth, startSize.width + dx))
        let newH = max(minHeight, startSize.height + dy)
        let newSize = NSSize(width: newW, height: newH)

        // Anchor the top-left: only the bottom-right corner follows
        // the cursor. The panel's frame.origin is the bottom-left in
        // AppKit, so to keep the top edge fixed when the height grows
        // we have to push the origin *down* by the height delta.
        // Without this, `setFrame` keeps the origin fixed and the
        // panel grows upward — away from the cursor, which feels
        // inverted (the "crece hacia arriba" bug).
        var newFrame = panel.frame
        let heightDelta = newSize.height - newFrame.size.height
        newFrame.size = newSize
        newFrame.origin.y -= heightDelta
        panel.setFrame(newFrame, display: true, animate: false)
        // Force the content view (and its blur backdrop) to redraw.
        // Without this, NSVisualEffectView's cached layer contents
        // leave a "ghost" of the previous frame visible at the new
        // bounds — especially noticeable at the edges where the
        // panel grows. The setNeedsDisplay → display cascade
        // refreshes the layer synchronously here.
        panel.contentView?.needsDisplay = true
        onResize?(newSize)
    }

    override func resetCursorRects() {
        let r = NSRect(x: bounds.width - 16, y: 0, width: 16, height: 16)
        // v2: KVC on NSCursor (`value(forKey: "_windowResizeUpRightCursor")`)
        // crashes at runtime on macOS 15.5 with SIGTRAP — NSCursor is not
        // KVC-compliant and the underscore-prefixed key trips
        // `valueForUndefinedKey:`. Just use the arrow cursor; AppKit still
        // handles the drag gesture correctly via mouseDown/Dragged below.
        addCursorRect(r, cursor: NSCursor.arrow)
    }
}

// MARK: - Preview

#if DEBUG
struct StickyNoteView_Previews: PreviewProvider {
    static var previews: some View {
        StickyNoteView(viewModel: {
            let vm = StickyNoteViewModel()
            vm.text = "Hello from toi_companion! This is a longer message that should make the panel grow downward to accommodate the full text without truncating with ellipsis."
            return vm
        }())
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.black)
    }
}
#endif
