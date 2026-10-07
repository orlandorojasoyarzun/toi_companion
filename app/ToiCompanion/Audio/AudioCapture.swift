import AVFoundation
import os.log

/// Captures audio from the default microphone using AVAudioEngine and
/// streams 16 kHz mono Float32 buffers to consumers (STT, RMS meter, etc.).
///
/// The hardware delivers buffers at its native format (typically 44.1 kHz
/// or 48 kHz stereo Float32). We resample + downmix to the STT format
/// (16 kHz mono Float32) inside `handleBuffer` using the closure-based
/// `AVAudioConverter.convert(to:error:withInputFrom:)` API — the simple
/// `convert(to:from:)` API throws paramErr (-50) on the 44.1 kHz stereo
/// → 16 kHz mono path. A fresh converter is built per buffer (the
/// converter object retains state across calls).
final class AudioCapture {

    private let logger = Logger(subsystem: "com.salem.toicompanion", category: "AudioCapture")
    private let engine = AVAudioEngine()

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var isCapturing = false

    /// Stream of audio buffers at the input node's native format.
    /// Buffers arrive on a high-priority background queue — not the main actor.
    let stream: AsyncStream<AVAudioPCMBuffer>

    /// Latest RMS power level, useful for visual feedback and tests.
    /// Updated on every buffer; safe to read from any thread.
    private let rmsLock = NSLock()
    private var _rms: Float = 0
    var rms: Float {
        get { rmsLock.lock(); defer { rmsLock.unlock() }; return _rms }
    }

    // MARK: - Init

    init() {
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation!
        self.stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            cont = continuation
        }
        self.continuation = cont
    }

    // MARK: - Lifecycle

    /// Starts the audio engine and begins streaming buffers.
    /// Idempotent: calling start() when already capturing is a no-op.
    func start() throws {
        guard !isCapturing else {
            NSLog("toi_companion: AudioCapture already running, ignoring duplicate start")
            return
        }

        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        NSLog("toi_companion: AudioCapture hardware format: \(hardwareFormat.sampleRate) Hz, \(hardwareFormat.channelCount) ch")

        // Tap at the hardware format. We do the sample-rate + channel
        // conversion in handleBuffer with a fresh AVAudioConverter per
        // buffer — the closure-based API is the only one that handles
        // 44.1 kHz stereo → 16 kHz mono, and the converter object keeps
        // state so re-using it across buffers gets stuck after one use.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: hardwareFormat
        ) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.handleBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
        NSLog("toi_companion: AudioCapture started, engine running")
    }

    /// Stops the audio engine and closes the stream.
    func stop() {
        guard isCapturing else {
            NSLog("toi_companion: AudioCapture stop() called but not capturing (idempotent)")
            return
        }
        NSLog("toi_companion: AudioCapture stopping (engine and stream)")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        isCapturing = false
        NSLog("toi_companion: AudioCapture stopped")
    }

    deinit {
        NSLog("toi_companion: AudioCapture deinit")
        stop()
    }

    // MARK: - Internal

    private var handleBufferCount = 0

    private func handleBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        handleBufferCount += 1
        let inputFrameCount = inputBuffer.frameLength
        let inputFormat = inputBuffer.format

        // Build a fresh converter every call. AVAudioConverter is stateful
        // and gets stuck after one use; recreating is the simplest fix.
        let outputFormat = AudioFormat.sttFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            NSLog("toi_companion: AudioCapture could not create converter")
            return
        }

        // Allocate the output buffer large enough to hold the worst-case
        // full conversion in one shot. For 44.1 kHz → 16 kHz with frame
        // size 4096, the output is ~1486 frames; round up generously.
        let outputCapacity = AVAudioFrameCount(
            Double(inputFrameCount) * outputFormat.sampleRate / inputFormat.sampleRate + 1024
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            NSLog("toi_companion: AudioCapture could not allocate output buffer")
            return
        }

        // Closure-based convert API. The closure is called repeatedly; we
        // hand it the whole input buffer the first time and signal
        // end-of-stream the second time. The closure's return type is
        // non-optional AVAudioPCMBuffer, so we return the same buffer
        // both times and rely on the status pointer to communicate
        // whether we want more data.
        var inputProvided = false
        var convertError: NSError?
        converter.convert(to: outputBuffer, error: &convertError) { _, outStatus in
            if !inputProvided {
                inputProvided = true
                outStatus.pointee = AVAudioConverterInputStatus.haveData
                return inputBuffer
            } else {
                outStatus.pointee = AVAudioConverterInputStatus.endOfStream
                return inputBuffer
            }
        }

        if let convertError = convertError {
            NSLog("toi_companion: AudioCapture convert error: \(convertError.localizedDescription)")
            return
        }

        let outputFrameCount = outputBuffer.frameLength
        if outputFrameCount == 0 {
            // No audio produced this round — skip silently. Happens
            // occasionally on the very first buffer while the converter
            // warms up.
            return
        }

        // Compute RMS for visual feedback (on the converted buffer).
        let rms = Self.computeRMS(outputBuffer)
        rmsLock.lock()
        _rms = rms
        rmsLock.unlock()

        continuation?.yield(outputBuffer)
    }

    /// Computes the root mean square (RMS) of a Float32 PCM buffer.
    /// Used for visual feedback and tests.
    private static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength  = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for i in 0..<frameLength {
                let sample = samples[i]
                sumOfSquares += sample * sample
            }
        }

        let totalSamples = Float(frameLength * channelCount)
        return sqrt(sumOfSquares / totalSamples)
    }
}

// MARK: - Errors

enum AudioCaptureError: Error, LocalizedError {
    case converterUnavailable

    var errorDescription: String? {
        switch self {
        case .converterUnavailable:
            return "Could not create audio converter from hardware format to 16 kHz mono Float32"
        }
    }
}
