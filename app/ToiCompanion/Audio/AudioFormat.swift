import AVFoundation
import os.log

/// Audio format constants used across the app.
/// The Apple SpeechAnalyzer wants 16 kHz mono Float32 input.
enum AudioFormat {

    /// Target format for the STT pipeline (SpeechAnalyzer).
    /// 16 kHz is the canonical rate for speech recognition.
    /// Mono (1 channel) — speech is mono by nature.
    /// Float32 — SpeechAnalyzer accepts Float32 PCM buffers.
    static let sttFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate:  16_000,
            channels:    1,
            interleaved: false
        ) else {
            fatalError("Could not create 16 kHz mono Float32 audio format")
        }
        return format
    }()

    /// Hardware-native format (the format the mic delivers at).
    /// The exact sample rate and channel count depend on the user's hardware
    /// (typically 44.1 kHz or 48 kHz, 1 or 2 channels).
    static var hardwareFormat: AVAudioFormat? {
        // The input node has a fixed format we can read at runtime.
        // We expose this through AudioCapture rather than statically.
        nil
    }
}
