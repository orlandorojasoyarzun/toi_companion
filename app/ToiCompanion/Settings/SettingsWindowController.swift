import AppKit
import SwiftUI
import os.log

/// Hosts the settings SwiftUI view in a regular `NSWindow`.
///
/// The window is singleton: tapping "Font Settings..." twice just
/// brings the existing window forward. Closing it (`x`) doesn't tear
/// the SwiftUI state down — the same `SettingsStore` instance lives
/// on, so the panel updates immediately next time it shows.
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private let logger = AppLogger.make("SettingsWindow")
    private var window: NSWindow?

    @MainActor
    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            logger.info("settings window re-shown")
            return
        }

        let view = SettingsView(store: SettingsStore.shared)
        let hosting = NSHostingController(rootView: view)

        let win = NSWindow(contentViewController: hosting)
        win.title = "Font Settings"
        win.setContentSize(NSSize(width: 380, height: 520))
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false  // keep state, just hide
        win.center()

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logger.info("settings window opened")
    }
}
