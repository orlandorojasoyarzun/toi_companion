import AppKit
import os.log

/// Controls the NSStatusItem in the menu bar.
/// Phase 1: shows a simple icon and a Quit menu item.
/// Later phases will add dynamic icons reflecting voice state and test menu items.
final class MenuBarController {

    private let logger = Logger(subsystem: "com.salem.toicompanion", category: "MenuBar")
    private var statusItem: NSStatusItem?

    init() {
        setupStatusItem()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: "toi_companion")
            button.image?.isTemplate = true
        }

        statusItem?.menu = buildMenu()
        logger.info("NSStatusItem created")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "About toi_companion", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    // MARK: - Public

    /// Updates the icon in the menu bar to reflect the current voice state.
    /// Called by CompanionManager as the state machine transitions.
    func updateState(_ state: String) {
        // Phase 1: no-op. Phase 5+ will swap the icon based on state.
        logger.debug("MenuBar state: \(state)")
    }
}
