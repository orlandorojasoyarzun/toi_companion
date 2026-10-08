import SwiftUI

/// Sticky note color themes. Phase 7: pick between DOS-blue, a Helix
/// editor-inspired purple, and a high-contrast taxi yellow.
///
/// The theme is just background + text colors plus a header opacity so
/// the `>toi_companion` line reads as a sub-label. The font/spacing
/// concerns live in `SettingsStore`; this enum is pure colors.
enum StickyNoteTheme: String, CaseIterable, Identifiable, Codable {
    case systemBlue  = "System Blue"
    case helixPurple = "Helix Purple"
    case taxiYellow  = "Taxi Yellow"

    var id: String { rawValue }

    /// Background of the panel.
    var background: Color {
        switch self {
        case .systemBlue:
            return Color(red: 0.0,  green: 0.0,  blue: 0.667)   // #0000AA DOS blue
        case .helixPurple:
            return Color(red: 0.227, green: 0.129, blue: 0.333) // #3A2155 — deep Helix-like violet
        case .taxiYellow:
            return Color(red: 1.0,  green: 0.85, blue: 0.0)     // bright taxi yellow
        }
    }

    /// Foreground (text) color. Picked to read well on the background
    /// without having to reason about contrast in the renderer.
    var text: Color {
        switch self {
        case .systemBlue, .helixPurple:
            return Color(red: 0.875, green: 0.875, blue: 0.875) // bright off-white
        case .taxiYellow:
            return Color.black
        }
    }

    /// Opacity for the `>toi_companion` header. Subdues it so the
    /// body text wins the eye, but on yellow we go slightly darker so
    /// the gray-on-yellow header doesn't look washed out.
    var headerOpacity: Double {
        switch self {
        case .systemBlue, .helixPurple: return 0.7
        case .taxiYellow:              return 0.6
        }
    }
}
