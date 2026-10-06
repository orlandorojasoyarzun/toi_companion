import AppKit

/// Application delegate. Sets up the menu bar controller on launch.
/// Phase 1: the menu bar icon appears, clicking Quit exits.
/// Phase 5+: CompanionManager and PushToTalkMonitor are wired here.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("toi_companion launched")

        // Phase 1: set up the menu bar icon.
        menuBarController = MenuBarController()

        // Phase 1 debug: show the sticky note when the app launches.
        // Remove this in Phase 2 — it proves the panel works without audio.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            StickyNotePanel.shared.show(initialText: "hello from toi_companion")
            // Auto-hide after 3s so it doesn't block your screen during dev.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                StickyNotePanel.shared.scheduleHide()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The app has no windows; quitting only happens via the menu bar item.
        return false
    }
}
