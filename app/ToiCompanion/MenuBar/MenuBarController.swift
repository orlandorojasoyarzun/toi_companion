import AppKit
import os.log

/// Controls the NSStatusItem in the menu bar.
/// Phase 1: shows a simple icon and a Quit menu item.
/// Phase 2: adds "Test Audio (5s)" which exercises the mic and logs RMS.
final class MenuBarController {

    private let logger = AppLogger.make("MenuBar")
    private var statusItem: NSStatusItem?

    /// Set by AppDelegate. The menu calls into this to trigger test captures.
    weak var actions: MenuBarActions?

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

        // Phase 2: trigger a 5-second mic test that logs RMS to the console.
        let testAudio = NSMenuItem(
            title: "Test Audio (5s)",
            action: #selector(MenuBarController.testAudioTapped),
            keyEquivalent: ""
        )
        testAudio.target = self
        menu.addItem(testAudio)

        // Phase 3: trigger a 3-second STT test that captures speech and
        // shows the transcript in the sticky note.
        let testSTT = NSMenuItem(
            title: "Test STT (3s)",
            action: #selector(MenuBarController.testSTTTapped),
            keyEquivalent: ""
        )
        testSTT.target = self
        menu.addItem(testSTT)

        // Phase 4: trigger an end-to-end LLM streaming test with a
        // hardcoded prompt. Proves Worker + SSE parser + sticky note
        // streaming before we wire PTT release to it.
        let testLLM = NSMenuItem(
            title: "Test LLM",
            action: #selector(MenuBarController.testLLMTapped),
            keyEquivalent: ""
        )
        testLLM.target = self
        menu.addItem(testLLM)

        menu.addItem(NSMenuItem.separator())

        // Phase 7: open the settings window. Font + size + line spacing
        // + theme are configured there, with a live preview.
        let fontSettings = NSMenuItem(
            title: "Font Settings…",
            action: #selector(MenuBarController.fontSettingsTapped),
            keyEquivalent: ","
        )
        fontSettings.target = self
        menu.addItem(fontSettings)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About toi_companion", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        return menu
    }

    // MARK: - Actions

    @objc private func testAudioTapped() {
        MainActor.assumeIsolated {
            logger.info("Test Audio triggered")
            actions?.didRequestTestAudio()
        }
    }

    @objc private func testSTTTapped() {
        MainActor.assumeIsolated {
            logger.info("Test STT triggered")
            actions?.didRequestTestSTT()
        }
    }

    @objc private func testLLMTapped() {
        MainActor.assumeIsolated {
            logger.info("Test LLM triggered")
            actions?.didRequestTestLLM()
        }
    }

    @objc private func fontSettingsTapped() {
        MainActor.assumeIsolated {
            logger.info("Font Settings triggered")
            actions?.didRequestFontSettings()
        }
    }

    // MARK: - Public

    /// Updates the icon in the menu bar to reflect the current voice state.
    /// Called by CompanionManager as the state machine transitions.
    func updateState(_ state: String) {
        // Phase 2: no-op. Phase 5+ will swap the icon based on state.
        logger.debug("MenuBar state: \(state)")
    }
}

/// Actions the menu can request. AppDelegate adopts this to bridge
/// menu items to the components they should drive. All methods run on
/// the main actor (NSMenu callbacks are always delivered on main).
@MainActor
protocol MenuBarActions: AnyObject {
    func didRequestTestAudio()
    func didRequestTestSTT()
    func didRequestTestLLM()
    func didRequestFontSettings()
}
