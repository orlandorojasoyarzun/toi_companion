import AppKit

/// Application delegate. In Phase 0 this only logs launch; later phases will
/// wire the `CompanionManager`, the menu bar controller, and the push-to-talk
/// monitor from `applicationDidFinishLaunching`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("toi_companion launched (Phase 0 — skeleton).")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The app has no windows; quitting only happens via the menu bar item.
        return false
    }
}