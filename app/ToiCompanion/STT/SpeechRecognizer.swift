import AVFoundation
import Speech
import os.log

/// Wraps Apple's `SFSpeechRecognizer` and feeds it audio buffers from
/// an `AsyncStream<AVAudioPCMBuffer>` (e.g. from `AudioCapture`).
///
/// Each push-to-talk session: call `start(stream:)` to begin recognition,
/// feed audio, then call `stop()` to finalise. Interim and final
/// transcript updates are emitted to the delegate on the main actor.
///
/// Implementation notes:
/// - Uses the legacy `SFSpeechAudioBufferRecognitionRequest` API
///   because `SpeechAnalyzer` requires macOS 26+ (project targets 13).
/// - Buffers come in on a background audio thread; recognition
///   callbacks arrive on a Speech-framework queue. Both feed the
///   accumulator via a serial queue.
/// - On-device recognition is OFF by default (`requiresOnDeviceRecognition = false`)
///   because the on-device model can require a first-use download on macOS 13.
final class SpeechRecognizer {

    private let logger = AppLogger.make("SpeechRecognizer")

    private let recognizer: SFSpeechRecognizer?
    private let locale: Locale

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Serial queue used to mutate the accumulator from whichever
    /// thread the callback arrives on.
    private let accumulatorQueue = DispatchQueue(label: "com.salem.toicompanion.stt.accumulator")
    private var accumulator = TranscriptAccumulator()

    /// Single-consumer task that drains the audio stream and feeds
    /// buffers to the active recognition request.
    private var streamTask: Task<Void, Never>?

    /// Counter of buffers forwarded to the request — for diagnostics.
    private var bufferCount: Int = 0

    /// Set by AppDelegate. All callbacks fire on the main actor.
    weak var delegate: SpeechRecognizerDelegate?

    /// Spanish by default (`es-ES`) — the user's system is `en-GB` but
    /// they speak Spanish, and `SFSpeechRecognizer` for `en-GB` produces
    /// nonsense when fed Spanish audio ("Bak ze Au Hola zha"). Apple's
    /// only other officially supported Spanish locale is `es-MX`.
    /// To override at runtime, pass a different locale to `init`.
    init(locale: Locale = Locale(identifier: "es-ES")) {
        self.locale = locale
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    // MARK: - Lifecycle

    /// Starts a new recognition session. The audio stream must produce
    /// `AVAudioPCMBuffer`s at a format compatible with SFSpeechRecognizer
    /// (typically 16 kHz mono Float32 — see `AudioFormat.sttFormat`).
    ///
    /// Idempotent: calling twice without `stop()` in between is a no-op.
    func start(stream: AsyncStream<AVAudioPCMBuffer>) throws {
        guard let recognizer = recognizer else {
            let localeID = locale.identifier
            NSLog("toi_companion: STT unavailable for locale \(localeID)")
            throw SpeechRecognizerError.localeUnsupported
        }
        guard recognizer.isAvailable else {
            NSLog("toi_companion: STT recognizer reports not available for locale \(recognizer.locale.identifier)")
            throw SpeechRecognizerError.recognizerUnavailable
        }
        guard streamTask == nil else {
            NSLog("toi_companion: STT already running, ignoring duplicate start")
            return
        }

        NSLog("toi_companion: STT starting (locale=\(recognizer.locale.identifier), available=\(recognizer.isAvailable))")
        accumulatorQueue.sync { accumulator.reset() }
        bufferCount = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        self.request = request

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                self.handleError(error)
                return
            }
            guard let result = result else {
                // SFSpeechRecognizer fires this path when audio ends with no
                // recognisable speech. Worth logging so we can tell the
                // difference between "still listening" and "gave up".
                NSLog("toi_companion: STT callback with nil result (no speech or end-of-stream)")
                return
            }
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            NSLog("toi_companion: STT callback isFinal=\(isFinal) text=\"\(text)\" segments=\(result.bestTranscription.segments.count)")

            var emitted: SpeechRecognizerEvent?
            self.accumulatorQueue.sync {
                self.accumulator.ingest(text: text, isFinal: isFinal)
                let current = self.accumulator.currentText
                emitted = isFinal
                    ? .finalized(text: current)
                    : .interimUpdated(text: current)
            }

            if let emitted = emitted {
                self.deliver(event: emitted)
            }

            if isFinal {
                self.cleanup()
            }
        }
        self.task = task

        // Drain the audio stream and forward each buffer to the request.
        // The Task body runs on a background executor; `append` and
        // `endAudio` on `SFSpeechAudioBufferRecognitionRequest` are
        // thread-safe.
        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await buffer in stream {
                guard let self = self else { return }
                guard !Task.isCancelled else { return }
                self.bufferCount += 1
                self.request?.append(buffer)
            }
            NSLog("toi_companion: STT stream ended, total buffers=\(self?.bufferCount ?? 0)")
            // Stream finished (AudioCapture stopped) — signal end of audio
            // so the recogniser delivers its last `isFinal == true` result.
            self?.request?.endAudio()
        }

        NSLog("toi_companion: STT started")
    }

    /// Stops the recognition session: ends audio, asks for a final
    /// result, and cancels the stream task. Safe to call when not started.
    func stop() {
        guard streamTask != nil || request != nil || task != nil else { return }
        NSLog("toi_companion: STT stopping (buffers=\(bufferCount))")

        // Cancel the stream drainer first — if we cancelled the request
        // first, the next buffer yield could race with cleanup.
        streamTask?.cancel()
        streamTask = nil

        request?.endAudio()
        // The recognitionTask callback will fire with isFinal == true,
        // which calls cleanup() and emits the final .finalized event.
        // We DON'T call task?.cancel() here — we want the final transcript.
    }

    // MARK: - Internal

    private func cleanup() {
        task?.finish()
        task = nil
        request = nil
        streamTask = nil
        NSLog("toi_companion: STT cleaned up")
    }

    private func handleError(_ error: Error) {
        let nsError = error as NSError
        NSLog("toi_companion: STT error domain=\(nsError.domain) code=\(nsError.code): \(error.localizedDescription)")
        deliver(event: .error(SpeechRecognizerError.recognitionFailed(nsError)))
        cleanup()
    }

    /// Hop to the main actor before calling the delegate, because the
    /// delegate's methods are `@MainActor` and we want UI updates to
    /// be predictable.
    private func deliver(event: SpeechRecognizerEvent) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.speechRecognizer(self, didEmit: event)
        }
    }
}

// MARK: - Events

/// What the recogniser observed during a session. The `text` on each
/// case is the FULL best displayable text at that moment (i.e.
/// finalised + latest interim).
enum SpeechRecognizerEvent {
    /// A new (or revised) best hypothesis; replaces any prior interim.
    case interimUpdated(text: String)
    /// The recogniser finalised the most recent text.
    case finalized(text: String)
    /// Something went wrong. The session is over.
    case error(Error)
}

protocol SpeechRecognizerDelegate: AnyObject {
    @MainActor func speechRecognizer(_ recognizer: SpeechRecognizer, didEmit event: SpeechRecognizerEvent)
}

// MARK: - Errors

enum SpeechRecognizerError: Error, LocalizedError {
    case localeUnsupported
    case recognizerUnavailable
    case recognitionFailed(NSError)

    var errorDescription: String? {
        switch self {
        case .localeUnsupported:
            return "Speech recognition is not supported for this locale."
        case .recognizerUnavailable:
            return "Speech recognition is temporarily unavailable."
        case .recognitionFailed(let nsError):
            return "Recognition failed (\(nsError.domain) #\(nsError.code)): \(nsError.localizedDescription)"
        }
    }
}