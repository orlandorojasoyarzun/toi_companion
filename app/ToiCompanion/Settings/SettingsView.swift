import SwiftUI

/// The settings window. Live preview at the bottom shows the chosen
/// font / size / spacing / theme applied to a mini sticky note — so the
/// user can see their changes without dismissing the window and
/// triggering one in the field.
struct SettingsView: View {

    @ObservedObject var store: SettingsStore

    /// Default panel size, mirrors `CursorPositioner.panelWidth` /
    /// `panelHeight` so the settings preview renders at the same
    /// dimensions the user sees when the panel first appears.
    /// Locked in `body` via `.frame(width:height:)` so the
    /// StickyNoteView doesn't grow vertically to fill the settings
    /// window's extra space — a 380pt-wide form with only ~140pt of
    /// useful content would otherwise leave the preview towering
    /// over the controls.
    private let previewSize = CGSize(width: 340, height: 140)

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

            // The preview renders the live `StickyNoteView` pinned to
            // the default panel size (340×140, matching
            // `CursorPositioner.panelWidth/Height` and the size the
            // user sees when the note first appears). Without the
            // explicit `frame(width:height:)`, the inner VStack's
            // `.frame(maxHeight: .infinity)` lets the preview grow
            // vertically to fill the settings window's slack, so the
            // note reads as "a giant block" instead of "a small
            // note like the one in the field".
            StickyNoteView(viewModel: previewViewModel)
                .frame(width: previewSize.width, height: previewSize.height)
                .environmentObject(store)
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Uses the same greeting text the user sees when the panel
    /// first appears, so the preview is a faithful "mini copy" of
    /// the real note — not a custom example that might be longer
    /// or shorter than what actually shows up in the field.
    private var previewViewModel: StickyNoteViewModel {
        let vm = StickyNoteViewModel()
        vm.text = "toi_companion is made by S𝑎lem.dev. Thank you for using it❤︎"
        return vm
    }
}
