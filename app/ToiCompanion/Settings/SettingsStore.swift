import Foundation
import SwiftUI
import os.log

/// Single source of truth for sticky-note presentation settings.
///
/// Held as a singleton because both the main panel and the settings
/// window need to observe the same values live — picking a font in the
/// settings window must immediately re-render the panel. Each property
/// persists to `UserDefaults` on `didSet` so a relaunch picks up where
/// the user left off.
///
/// All mutations happen on the main actor; SwiftUI views can observe
/// it via `@ObservedObject` and re-render automatically.
@MainActor
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    // MARK: - Persisted values

    @Published var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Keys.fontFamily) }
    }

    /// Stored as Double because `Slider` works in Double and we don't
    /// want a second type to round-trip.
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }

    @Published var lineSpacing: Double {
        didSet { defaults.set(lineSpacing, forKey: Keys.lineSpacing) }
    }

    @Published var theme: StickyNoteTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    // MARK: - Constants

    /// Coder monospaced fonts that ship with macOS. Ordered roughly
    /// from most-loved to most-fallback; `Menlo` is the default and
    /// reads well at 13pt.
    let availableFonts: [String] = [
        "Menlo",
        "Monaco",
        "SF Mono",
        "Courier New",
        "Andale Mono",
    ]

    // MARK: - Internals

    private enum Keys {
        static let fontFamily  = "settings.fontFamily"
        static let fontSize    = "settings.fontSize"
        static let lineSpacing = "settings.lineSpacing"
        static let theme       = "settings.theme"
    }

    private let defaults: UserDefaults
    private let logger = AppLogger.make("SettingsStore")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        self.fontFamily  = defaults.string(forKey: Keys.fontFamily) ?? "Menlo"
        // `object(forKey:)` so an absent key doesn't coerce to 0.
        self.fontSize    = defaults.object(forKey: Keys.fontSize) as? Double ?? 13
        self.lineSpacing = defaults.object(forKey: Keys.lineSpacing) as? Double ?? 1.2
        let raw          = defaults.string(forKey: Keys.theme) ?? StickyNoteTheme.systemBlue.rawValue
        self.theme       = StickyNoteTheme(rawValue: raw) ?? .systemBlue

        logger.info("loaded: font=\(self.fontFamily), size=\(self.fontSize), spacing=\(self.lineSpacing), theme=\(self.theme.rawValue)")
    }
}
