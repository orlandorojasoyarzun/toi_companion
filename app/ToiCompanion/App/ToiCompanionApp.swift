import SwiftUI

@main
struct ToiCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app has no main window (LSUIElement = true in Info.plist).
        // We still need a Scene for the SwiftUI App lifecycle; Settings is the
        // least-invasive choice and is reachable programmatically later.
        Settings {
            EmptyView()
        }
    }
}