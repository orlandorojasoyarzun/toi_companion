import AppKit

/// Application delegate. Sets up the menu bar controller on launch,
/// runs the permission gate, and wires the push-to-talk hotkey to
/// the audio capture + sticky note.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Owned components

    private var menuBarController: MenuBarController?
    private let permissionGate = PermissionGate()
    private let pushToTalk = PushToTalkMonitor(key: .rightShift)
    private var audioCapture: AudioCapture?

    /// When did the current push-to-talk session start? Used to report
    /// duration in the sticky note. nil when not in a session.
    private var pttStartTime: Date?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("toi_companion launched")

        // Menu bar.
        let menu = MenuBarController()
        menu.actions = self
        menuBarController = menu

        // Phase 2: request mic + speech recognition permission on first launch.
        Task { @MainActor in
            let result = await permissionGate.requestAllPermissions()
            NSLog("toi_companion permissions: mic=\(result.mic.rawValue), speech=\(result.speech.rawValue)")
        }

        // Phase 2.5: start the push-to-talk listener (Right Shift in dev,
        // Right Option in v1.0). Wired to audio capture + sticky note.
        pushToTalk.delegate = self
        pushToTalk.start()

        // Phase 1 debug: show the sticky note when the app launches.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            StickyNotePanel.shared.show(initialText: "hello from toi_companion")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                StickyNotePanel.shared.scheduleHide()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

// MARK: - MenuBarActions

extension AppDelegate: MenuBarActions {

    /// 5-second mic test from the menu. Logs RMS so the user can confirm
    /// in Console.app that audio is actually flowing in.
    func didRequestTestAudio() {
        NSLog("toi_companion: starting 5s audio test")

        if audioCapture == nil {
            audioCapture = AudioCapture()
        }
        guard let capture = audioCapture else { return }

        do {
            try capture.start()
        } catch {
            NSLog("toi_companion: failed to start audio: \(error.localizedDescription)")
            return
        }

        for delay in stride(from: 0.5, through: 5.0, by: 0.5) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSLog(String(format: "toi_companion audio test t=%.1fs rms=%.4f", delay, capture.rms))
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            capture.stop()
            NSLog("toi_companion: audio test finished")
        }
    }
}

// MARK: - PushToTalkMonitorDelegate

extension AppDelegate: PushToTalkMonitorDelegate {

    @MainActor
    func pushToTalkDidPress() {
        NSLog("toi_companion: PTT press")

        if audioCapture == nil {
            audioCapture = AudioCapture()
        }
        guard let capture = audioCapture else { return }

        do {
            try capture.start()
        } catch {
            NSLog("toi_companion: failed to start audio on PTT: \(error.localizedDescription)")
            StickyNotePanel.shared.show(initialText: "mic error")
            StickyNotePanel.shared.scheduleHide()
            return
        }

        pttStartTime = Date()
        StickyNotePanel.shared.show(initialText: "Listening...")
    }

    @MainActor
    func pushToTalkDidRelease() {
        NSLog("toi_companion: PTT release")

        let duration: String
        if let start = pttStartTime {
            let seconds = Date().timeIntervalSince(start)
            duration = String(format: "%.1fs", seconds)
        } else {
            duration = "0.0s"
        }
        pttStartTime = nil

        audioCapture?.stop()
        StickyNotePanel.shared.updateText("Heard \(duration)")
        StickyNotePanel.shared.scheduleHide()
    }
}
