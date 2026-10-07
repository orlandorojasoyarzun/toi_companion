import SwiftUI

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
/// close button on the right. The X is the explicit close affordance;
/// the body still closes on click for muscle-memory users, and the
/// grip is the dedicated drag zone (system window drag).
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

    /// Width grows *slowly* with character count. Phase 7.4: a wider
    /// multiplier (was 0.6) made the panel widen so much that text
    /// wrapped to fewer lines, which kept the total height constant
    /// and made the note look "stuck" mid-growth. Capping at 380 with
    /// a 0.25 multiplier keeps width meaningful but always lets text
    /// wrap to enough lines that height grows monotonically with the
    /// number of characters.
    private var preferredWidth: CGFloat {
        let chars = viewModel.text.count
        let growth = CGFloat(chars) * 0.25
        return min(maxPanelWidth, max(minPanelWidth, minPanelWidth + growth))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .frame(width: preferredWidth)
        .frame(minHeight: minPanelHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 20pt strip at the very top. Drag handle (☐) on the left, close
    /// button (×) on the right. Background is the same theme colour
    /// as the body, so the panel reads as one solid block with
    /// controls painted on top — instead of a grey blur strip.
    private var topBar: some View {
        HStack(spacing: 0) {
            // Drag handle — a single ☐ (BALLOT BOX) glyph in the muted
            // header color. The actual drag is triggered by the parent
            // NSPanel's mouseDown when the click lands in the top 20pt;
            // this view only paints the affordance.
            Text("☐")
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundColor(settings.theme.text.opacity(0.55))
                .frame(width: 22, height: Self.topBarHeight)
                .padding(.leading, 8)

            Spacer()

            // X close button. Plain style so it inherits the theme color.
            // Sized 22×20. SwiftUI's Button consumes the mouseDown so the
            // parent's drag-handler doesn't fire for this region.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(settings.theme.text.opacity(0.7))
                    .frame(width: 22, height: Self.topBarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
        .frame(height: Self.topBarHeight)
        .background(
            Rectangle()
                .fill(settings.theme.background)
        )
    }

    /// The original sticky-note content: filled background rectangle
    /// + VStack with the `>toi_companion` header and the body text.
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

                Text(viewModel.text.isEmpty ? "..." : viewModel.text)
                    .font(.custom(settings.fontFamily, size: settings.fontSize))
                    .foregroundColor(settings.theme.text)
                    .multilineTextAlignment(.leading)
                    // lineSpacing is in points (gap added between lines),
                    // not a multiplier — so 1.2 at 13pt ≈ +2.6pt.
                    .lineSpacing(settings.fontSize * (settings.lineSpacing - 1.0))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(padding)
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
