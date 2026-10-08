import Foundation
import os.log

/// Centralised `os.Logger` factory. Every component logs under the
/// `com.salem.toicompanion` subsystem with its own category.
enum AppLogger {

    /// The subsystem shared by every logger in the app.
    /// Reverse-DNS, matches the bundle identifier prefix.
    static let subsystem = "com.salem.toicompanion"

    /// Returns a logger for a given category. Use short, snake_case names.
    /// Examples: "AudioCapture", "PermissionGate", "MenuBar", "StickyNote".
    static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
