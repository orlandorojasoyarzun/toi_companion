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

    private let cornerRadius: CGFloat = 0  // DOS has sharp corners
    private let padding: CGFloat = 12

    /// Panel width bounds. The actual width is a smooth function of the
    /// text length — see `preferredWidth` below — but it never goes
    /// outside this range.
    private let minPanelWidth: CGFloat = 280
    private let maxPanelWidth: CGFloat = 380
    /// Floor for the panel's height. Matches `StickyNotePanel.minPanelHeight`
    /// so an empty / very-short note still reads as a deliberate note.
    private let minPanelHeight: CGFloat = 140

    /// Height of the top control bar. Kept in sync with the parent's
    /// `mouseDown` check so clicks in this band start a window drag
    /// instead of a close.
    static let topBarHeight: CGFloat = 20

    /// Height of the bottom resize grip strip.
    private let bottomGripHeight: CGFloat = 12

    /// Width grows *slowly* with character count. Phase 7.4: a wider
    /// multiplier (was 0.6) made the panel widen so much that text
    /// wrapped to fewer lines, which kept the total height constant
    /// and made the note look "stuck" mid-growth. Capping at 380 with
    /// a 0.25 multiplier keeps width meaningful but always lets text
    /// wrap to enough lines that height grows monotonically with the
    /// number of characters.
    private var preferredWidth: CGFloat {
        if let userSize = viewModel.userSize {
            return max(minPanelWidth, min(maxPanelWidth, userSize.width))
        }
        let chars = viewModel.text.count
        let growth = CGFloat(chars) * 0.25
        return min(maxPanelWidth, max(minPanelWidth, minPanelWidth + growth))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
            bottomGrip
        }
        .frame(width: preferredWidth)
        .frame(minHeight: minPanelHeight)
        .fixedSize(horizontal: false, vertical: true)
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
            .padding(.leading, 6)

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
            .padding(.trailing, 8)
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
                        lineSpacing: settings.fontSize * (settings.lineSpacing - 1.0)
                    )
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    // STATIC MODE.
                    Text(viewModel.text.isEmpty ? "..." : viewModel.text)
                        .font(.custom(settings.fontFamily, size: settings.fontSize))
                        .foregroundColor(settings.theme.text)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(settings.fontSize * (settings.lineSpacing - 1.0))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(padding)
        }
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
        let willEdit = !viewModel.isEditing
        viewModel.isEditing = willEdit
        if willEdit {
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
        let dx = event.locationInWindow.x - dragStart.x
        let dy = event.locationInWindow.y - dragStart.y  // flipped coord: y up = positive

        let newW = max(minWidth, min(maxWidth, startSize.width + dx))
        let newH = max(minHeight, startSize.height + dy)
        let newSize = NSSize(width: newW, height: newH)

        // Anchor the top-left; only bottom-right grows.
        var newFrame = panel.frame
        newFrame.size = newSize
        panel.setFrame(newFrame, display: true, animate: false)
        onResize?(newSize)
    }

    override func resetCursorRects() {
        let r = NSRect(x: bounds.width - 16, y: 0, width: 16, height: 16)
        // NSCursor has no `resizeUpRight` symbol — use the cross-version
        // private selector path. AppKit exposes these as +[NSCursor _windowResizeUpRightCursor]
        // in some SDKs, but the supported way is the bridged constant
        // from the framework header. As a safe fallback we use the
        // diagonal-resize cursor that has been available since 10.6.
        if let cursor = NSCursor.value(forKey: "_windowResizeUpRightCursor") as? NSCursor {
            addCursorRect(r, cursor: cursor)
        } else {
            addCursorRect(r, cursor: NSCursor.arrow)
        }
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
