import SwiftUI

/// SwiftUI view rendered inside the sticky note panel.
/// Phase 1: simple text with a pill-style indicator. Later adds streaming text.
struct StickyNoteView: View {

    @ObservedObject var viewModel: StickyNoteViewModel

    private let cornerRadius: CGFloat = 0  // DOS has sharp corners
    private let padding: CGFloat = 12
    private let fontSize: CGFloat = 13

    // MS-DOS classic color palette.
    private let dosBlue   = Color(red: 0.0,  green: 0.0,  blue: 0.667)  // #0000AA
    private let dosWhite  = Color(red: 0.875, green: 0.875, blue: 0.875)  // bright white

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Solid DOS-blue background. The visual effect view in the parent
            // panel handles the rounded-corner clipping.
            Rectangle()
                .fill(dosBlue)

            VStack(alignment: .leading, spacing: 4) {
                // Optional caret/header line for that CRT feel.
                HStack(spacing: 4) {
                    Text(">")
                        .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                        .foregroundColor(dosWhite)
                    Text("toi_companion")
                        .font(.system(size: fontSize - 1, weight: .regular, design: .monospaced))
                        .foregroundColor(dosWhite.opacity(0.7))
                }

                Text(viewModel.text.isEmpty ? "..." : viewModel.text)
                    .font(.system(size: fontSize, weight: .regular, design: .monospaced))
                    .foregroundColor(dosWhite)
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(padding)
        }
        .frame(width: 260, height: 140)
    }
}

// MARK: - Preview

#if DEBUG
struct StickyNoteView_Previews: PreviewProvider {
    static var previews: some View {
        StickyNoteView(viewModel: {
            let vm = StickyNoteViewModel()
            vm.text = "Hello from toi_companion!"
            return vm
        }())
        .frame(width: 260, height: 140)
        .background(Color.black)
    }
}
#endif
