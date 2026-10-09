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

    /// Phase 4: LLM streaming client. Cached — holds the TLS-warm-up
    /// timer. Cancellation goes through `currentLLMTask`, not this.
    private let llmClient: LLMClient = OpenAIClient(
        workerURL: LLMConfig.workerBaseURL,
        secret: LLMConfig.sharedSecret
    )

    /// The in-flight LLM stream task, if any. Stored so a re-press or
    /// a new STT final can cancel the previous stream before starting
    /// a fresh one — otherwise the old stream keeps writing to the
    /// sticky note and stomping the new one.
    private var currentLLMTask: Task<Void, Never>?

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

        // Wire the panel's "send" callback to the LLM runner. The
        // StickyNoteView calls this from Enter / ✓ after the user
        // has reviewed (and optionally edited) the transcript.
        StickyNotePanel.shared.onSendRequested = { [weak self] text in
            self?.sendCurrentTranscript(text)
        }

        // Tell the panel how to find the menu bar icon so every
        // `show()` anchors just below it. The closure reads the
        // icon's current screen frame on each invocation — cheap,
        // and stays correct if the system menu bar layout reflows
        // (e.g. another app installs a status item). Returns nil
        // only if the icon's window hasn't materialised yet, in
        // which case the panel falls back to the cursor position.
        StickyNotePanel.shared.menuBarFrameProvider = { [weak menu] in
            guard let button = menu?.statusItem?.button,
                  button.window != nil else { return nil }
            return button.convert(button.bounds, to: nil)
        }

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
        // get clobbered by the auto-hide. The panel anchors below
        // the menu bar icon (via `menuBarFrameProvider` set above),
        // so the user sees it in a predictable spot — same place
        // every show, even after dragging it elsewhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !self.hasInteracted else { return }
            StickyNotePanel.shared.show(
                initialText: "Greetings from toitoi.dev: Use right Shift▲ and ask me anything."
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
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

    /// Phase 4: send a hardcoded prompt to the LLM and stream the
    /// response into the sticky note. Pure component test — bypasses
    /// the mic and STT so we can isolate Worker + SSE parser + UI
    /// streaming without speaking.
    @MainActor
    func didRequestTestLLM() {
        NSLog("toi_companion: Test LLM triggered")

        StickyNotePanel.shared.show(initialText: "asking LLM...")

        // Cancel any previous Test LLM stream (e.g. user double-clicked).
        currentLLMTask?.cancel()
        currentLLMTask = Task { @MainActor in
            await self.runLLMStream(
                systemPrompt: "Be concise. Respond in the user's language.",
                userPrompt: "Dime en una frase corta qué hace toi_companion, como si fueras un amigo.",
                errorPrefix: "llm error"
            )
        }
    }

    /// Phase 7: open the settings window. Singleton inside the
    /// controller, so a second click just brings the existing window
    /// forward instead of stacking new ones.
    @MainActor
    func didRequestFontSettings() {
        NSLog("toi_companion: Font Settings triggered")
        SettingsWindowController.shared.show()
    }

    /// Send the panel's current transcript to the LLM. Triggered by
    /// the sticky note's Enter key (NSTextView insertNewline) or the
    /// ✓ button in the top bar. Mirrors the .finalized branch that
    /// used to auto-send, but only fires when the user explicitly
    /// confirms. Empty / whitespace-only text → hide (nothing to
    /// ask).
    @MainActor
    private func sendCurrentTranscript(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            StickyNotePanel.shared.hide()
            return
        }
        currentLLMTask?.cancel()
        currentLLMTask = Task { @MainActor in
            await self.runLLMStream(
                systemPrompt: "Be concise. Respond in the user's language.",
                userPrompt: text,
                errorPrefix: "llm"
            )
        }
    }

    /// Shared LLM-stream runner. Sends the messages, paints progress
    /// to the sticky note, and schedules the hide on completion. Both
    /// the Test LLM menu and the PTT-release pipeline funnel through
    /// here so cancellation / error / hide behaviour stays consistent.
    @MainActor
    private func runLLMStream(
        systemPrompt: String,
        userPrompt: String,
        errorPrefix: String
    ) async {
        // Freeze the panel's size during the stream so the rapid
        // updateText() → resizeToFit() → setFrame() chain doesn't
        // cause visual glitches and z-order drops. The defer
        // unfreezes and triggers a final resize with the complete
        // response, no matter how this function exits.
        StickyNotePanel.shared.setIsStreaming(true)
        defer { StickyNotePanel.shared.setIsStreaming(false) }

        let messages = [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: userPrompt),
        ]
        do {
            let final = try await llmClient.stream(
                messages: messages,
                model: LLMConfig.defaultModel,
                maxTokens: LLMConfig.maxOutputTokens
            ) { accumulated in
                // Hop to main for the UI. `onProgress` is called from
                // URLSession's byte stream — not the main thread.
                Task { @MainActor in
                    StickyNotePanel.shared.updateText(accumulated)
                }
            }
            NSLog("toi_companion: LLM final (\(final.count) chars)")
            StickyNotePanel.shared.updateText(final)
            // Stay until the user clicks — 2 seconds isn't enough to read.
            StickyNotePanel.shared.stayUntilClick()
        } catch is CancellationError {
            // A re-press cancelled us. Don't overwrite the sticky note
            // — the new pipeline owns it now.
            NSLog("toi_companion: LLM stream cancelled")
        } catch {
            NSLog("toi_companion: LLM error: \(error.localizedDescription)")
            StickyNotePanel.shared.updateText("\(errorPrefix): \(error.localizedDescription)")
            StickyNotePanel.shared.stayUntilClick()
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
        StickyNotePanel.shared.show(initialText: "Listening ...")

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

            // Detach from any previous recogniser before creating a fresh
            // one. The old recogniser's failsafe holds a strong self
            // capture to survive AppDelegate's nil-out — without clearing
            // the delegate here, a stale `.finalized` synthesised after
            // the new PTT press would clobber the new session's transcript
            // and kick off a second LLM stream.
            speechRecognizer?.delegate = nil

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
        // with the complete transcript and hand the panel off to the
        // LLM stream runner, which owns the panel's lifecycle from here
        // (stayUntilClick on success/error, scheduleHide on silence).
        //
        // No auto-hide here — if we schedule one and the LLM response
        // takes longer than 2s, the panel disappears before the user can
        // read it. The STT failsafe (strong self capture + 1.5s synth-
        // final) ensures `.finalized` always fires, so the silence branch
        // is the only path that needs an explicit hide.
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

            // Silence — nothing to send. Keep the duration safety-net
            // hide from pushToTalkDidRelease (it's already pending).
            if text.isEmpty {
                StickyNotePanel.shared.updateText("(silence)")
                StickyNotePanel.shared.scheduleHide()
                return
            }

            // v2 edit-on-finalize: paint the transcript, cancel any
            // in-flight LLM stream (a new send will start a new one),
            // and enter edit mode so the user can correct it before
            // pressing Enter (or the ✓ button) to actually send. This
            // matches the v1 flow where the message wasn't sent by
            // itself — Enter is the explicit "go" trigger.
            StickyNotePanel.shared.updateText(text)
            currentLLMTask?.cancel()
            StickyNotePanel.shared.beginEditMode()
        case .error(let error):
            NSLog("toi_companion: STT error: \(error.localizedDescription)")
            // Empty body, auto-hide. The user tapped Shift briefly (e.g.
            // to type a capital) and we don't want a click-to-close panel
            // lingering with no content. The error detail is in the log.
            StickyNotePanel.shared.updateText("")
            StickyNotePanel.shared.scheduleHide()
        }
    }
}
