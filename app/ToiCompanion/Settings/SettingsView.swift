import SwiftUI

/// The settings window. Live preview at the bottom shows the chosen
/// font / size / spacing / theme applied to a mini sticky note — so the
/// user can see their changes without dismissing the window and
/// triggering one in the field.
struct SettingsView: View {

    @ObservedObject var store: SettingsStore

    private let previewWidth: CGFloat = 280

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Sticky Note Settings")
                .font(.headline)

            Form {
                Picker("Font", selection: $store.fontFamily) {
                    ForEach(store.availableFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }

                HStack {
                    Text("Size")
                    Slider(
                        value: $store.fontSize,
                        in: 8...24,
                        step: 1
                    )
                    Text("\(Int(store.fontSize))pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                HStack {
                    Text("Line spacing")
                    Slider(
                        value: $store.lineSpacing,
                        in: 1.0...2.0,
                        step: 0.1
                    )
                    Text(String(format: "%.1fx", store.lineSpacing))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                Picker("Theme", selection: $store.theme) {
                    ForEach(StickyNoteTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider()

            Text("Preview")
                .font(.subheadline)

            StickyNoteView(viewModel: previewViewModel)
                .frame(width: previewWidth)
                .environmentObject(store)
        }
        .padding(20)
        .frame(width: 380)
    }

    /// A stand-in for whatever the LLM is streaming back. Long enough
    /// to demonstrate that the panel grows with the text and that the
    /// chosen line spacing looks right.
    private var previewViewModel: StickyNoteViewModel {
        let vm = StickyNoteViewModel()
        vm.text = "Hola toi_companion! Puedo ayudarte con código, ideas, traducciones, lo que necesites."
        return vm
    }
}
