import AppKit

/// Application delegate. Sets up the menu bar controller on launch,
/// runs the permission gate, and wires the push-to-talk hotkey to
/// the audio capture + STT + sticky note.
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Owned components

    private var menuBarController: MenuBarController?
    private let permissionGate = PermissionGate()
    private let pushToTalk = PushToTalkMonitor(key: .rightShift)
    // Note: audioCapture and speechRecognizer are NOT cached. Each push-to-talk
    // session creates fresh instances. Caching leads to a dead AsyncStream
    // continuation (AudioCapture.stop() finishes the continuation, and the
    // stream is `let` — so the next press has no live consumer for buffers).
    private var audioCapture: AudioCapture?
    private var speechRecognizer: SpeechRecognizer?

    /// When did the current push-to-talk session start? Used to report
    /// duration in the sticky note. nil when not in a session.
    private var pttStartTime: Date?

    /// Set the first time the user presses Right Shift (or the test menu
    /// shows the panel). The launch greeting checks this before showing or
    /// auto-hiding, so a PTT press during the greeting's 5-second window
    /// isn't undone by a stale scheduleHide.
    private var hasInteracted = false

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
        // Right Option in v1.0). Wired to audio capture + STT + sticky note.
        pushToTalk.delegate = self
        pushToTalk.start()

        // Phase 1+ friendly greeting: show the sticky note ~1.5s after
        // launch so the user can confirm the app is alive. Gated by
        // `hasInteracted` so a quick PTT press during this window doesn't
        // get clobbered by the auto-hide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !self.hasInteracted else { return }
            StickyNotePanel.shared.show(initialText: "Ready. Hold Right Shift to talk.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard !self.hasInteracted else { return }
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
    @MainActor
    func didRequestTestAudio() {
        NSLog("toi_companion: starting 5s audio test")

        Task { @MainActor in
            // Wait for mic permission first; the OS prompt is async and
            // calling capture.start() before the user grants throws.
            let micStatus = await permissionGate.requestMicrophonePermission()
            guard micStatus == .granted else {
                NSLog("toi_companion: mic permission not granted (\(micStatus.rawValue))")
                return
            }

            // Fresh AudioCapture every test — same single-consumer-stream
            // reason as the push-to-talk path.
            let capture = AudioCapture()
            audioCapture = capture
            do {
                try capture.start()
            } catch {
                NSLog("toi_companion: failed to start audio: \(error.localizedDescription)")
                audioCapture = nil
                return
            }

            for delay in stride(from: 0.5, through: 5.0, by: 0.5) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSLog(String(format: "toi_companion audio test t=%.1fs rms=%.4f", delay, capture.rms))
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
                capture.stop()
                self.audioCapture = nil
                NSLog("toi_companion: audio test finished")
            }
        }
    }

    /// 3-second STT test from the menu. Captures audio, runs SpeechRecognizer,
    /// and shows interim/final transcripts in the sticky note.
    @MainActor
    func didRequestTestSTT() {
        NSLog("toi_companion: starting 3s STT test")

        Task { @MainActor in
            // Wait for mic permission first; see didRequestTestAudio().
            let micStatus = await permissionGate.requestMicrophonePermission()
            guard micStatus == .granted else {
                NSLog("toi_companion: mic permission not granted (\(micStatus.rawValue))")
                StickyNotePanel.shared.show(initialText: "mic denied")
                StickyNotePanel.shared.scheduleHide()
                return
            }

            // Fresh AudioCapture + SpeechRecognizer every test — see
            // pushToTalkDidPress for the single-consumer-stream reason.
            let capture = AudioCapture()
            audioCapture = capture
            // Show feedback immediately; update if setup fails.
            StickyNotePanel.shared.show(initialText: "Speak now (3s)...")

            do {
                try capture.start()
            } catch {
                NSLog("toi_companion: failed to start audio for STT test: \(error.localizedDescription)")
                StickyNotePanel.shared.updateText("mic error")
                StickyNotePanel.shared.scheduleHide()
                audioCapture = nil
                return
            }

            let stt = SpeechRecognizer()
            stt.delegate = self
            speechRecognizer = stt
            var startedSTT = false
            do {
                try stt.start(stream: capture.stream)
                startedSTT = true
            } catch {
                NSLog("toi_companion: STT unavailable for test: \(error.localizedDescription)")
            }

            if !startedSTT {
                StickyNotePanel.shared.updateText("STT unavailable")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                stt.stop()
                // Give the final-result callback ~1.5s to arrive before we
                // hide the panel (otherwise the user might miss it).
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    capture.stop()
                    self.audioCapture = nil
                    self.speechRecognizer = nil
                    NSLog("toi_companion: STT test finished")
                }
            }
        }
    }
}

// MARK: - PushToTalkMonitorDelegate

extension AppDelegate: PushToTalkMonitorDelegate {

    @MainActor
    func pushToTalkDidPress() {
        NSLog("toi_companion: PTT press")
        hasInteracted = true

        // Show feedback IMMEDIATELY so the user always sees something
        // happen on press, even while we wait for the OS permission prompt.
        pttStartTime = Date()
        StickyNotePanel.shared.show(initialText: "Listening...")

        // CRITICAL: wait for mic permission BEFORE touching AVAudioEngine.
        // On macOS the OS mic prompt is async; if we call engine.start()
        // before the user clicks Allow, it throws and we abort the press
        // flow. We must await the permission explicitly.
        Task { @MainActor in
            let micStatus = await permissionGate.requestMicrophonePermission()
            guard micStatus == .granted else {
                NSLog("toi_companion: mic permission not granted (\(micStatus.rawValue))")
                StickyNotePanel.shared.updateText("mic denied")
                StickyNotePanel.shared.scheduleHide()
                return
            }

            // Create FRESH instances every press. The previous session's
            // AudioCapture.stream is a single-consumer AsyncStream that
            // got finished in stop() — re-using it would deliver buffers
            // to nobody, and STT would sit silent.
            let capture = AudioCapture()
            audioCapture = capture
            do {
                try capture.start()
            } catch {
                NSLog("toi_companion: failed to start audio: \(error.localizedDescription)")
                StickyNotePanel.shared.updateText("mic error")
                StickyNotePanel.shared.scheduleHide()
                audioCapture = nil
                return
            }

            // STT is best-effort: if the recognizer is unavailable
            // (permission denied, locale unsupported, etc.) the press
            // flow still works — we just won't get a transcript.
            let stt = SpeechRecognizer()
            stt.delegate = self
            speechRecognizer = stt
            do {
                try stt.start(stream: capture.stream)
            } catch {
                NSLog("toi_companion: STT unavailable (\(error.localizedDescription)) — press flow without transcript")
            }
        }
    }

    @MainActor
    func pushToTalkDidRelease() {
        NSLog("toi_companion: PTT release")
        pttStartTime = nil

        // Stop the recogniser first so it can deliver its `finalized`
        // event. The actual sticky-note text update happens via the
        // SpeechRecognizerDelegate callback below.
        speechRecognizer?.stop()
        audioCapture?.stop()
        // Drop references so the next press starts from a clean slate.
        // The previous AudioCapture.stream is a single-consumer stream
        // whose continuation is finished — keeping it around would just
        // be a footgun.
        audioCapture = nil
        speechRecognizer = nil

        // Don't overwrite the live interim transcript with a duration
        // string — the user wants to keep seeing what they said. The
        // final callback (in the .finalized event) will replace the text
        // with the complete transcript and schedule the hide. This
        // scheduleHide is a safety net for the case where the final
        // callback never arrives (e.g. recogniser gives up with no
        // speech).
        StickyNotePanel.shared.scheduleHide()
    }
}

// MARK: - SpeechRecognizerDelegate

extension AppDelegate: SpeechRecognizerDelegate {

    @MainActor
    func speechRecognizer(_ recognizer: SpeechRecognizer, didEmit event: SpeechRecognizerEvent) {
        switch event {
        case .interimUpdated(let text):
            NSLog("toi_companion: STT interim: \(text)")
            StickyNotePanel.shared.updateText(text)
        case .finalized(let text):
            NSLog("toi_companion: STT final: \(text)")
            StickyNotePanel.shared.updateText(text.isEmpty ? "(silence)" : text)
            StickyNotePanel.shared.scheduleHide()
        case .error(let error):
            NSLog("toi_companion: STT error: \(error.localizedDescription)")
            StickyNotePanel.shared.updateText("stt: \(error.localizedDescription)")
            StickyNotePanel.shared.scheduleHide()
        }
    }
}