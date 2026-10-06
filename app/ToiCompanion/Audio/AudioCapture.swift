import AVFoundation
import os.log

/// Captures audio from the default microphone using AVAudioEngine and
/// streams downsampled buffers to consumers (STT, RMS meter, etc.).
///
/// Phase 2: provides the raw input tap and an AsyncStream of buffers
/// at the STT's target format (16 kHz mono Float32).
final class AudioCapture {

    private let logger = Logger(subsystem: "com.salem.toicompanion", category: "AudioCapture")
    private let engine = AVAudioEngine()
    private let converter: AVAudioConverter?

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var isCapturing = false

    /// Stream of audio buffers at the STT's target format.
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
        // Build the converter once: hardware → STT format.
        // We'll set the source format when the engine starts (it has a
        // hardware-specific input format we can't know in advance).
        self.converter = nil

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
            logger.debug("AudioCapture already running")
            return
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Input format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) channels")

        // Build a fresh converter for this hardware format.
        let converter = AVAudioConverter(from: inputFormat, to: AudioFormat.sttFormat)
        guard let converter = converter else {
            throw AudioCaptureError.converterUnavailable
        }

        // Install the tap. The closure runs on a background audio thread.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.handleBuffer(buffer, converter: converter)
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
        logger.info("AudioCapture started")
    }

    /// Stops the audio engine and closes the stream.
    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        isCapturing = false
        logger.info("AudioCapture stopped")
    }

    deinit {
        stop()
    }

    // MARK: - Internal

    private func handleBuffer(_ inputBuffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        // Compute RMS for visual feedback.
        let rms = Self.computeRMS(inputBuffer)
        rmsLock.lock()
        _rms = rms
        rmsLock.unlock()

        // Convert to STT format.
        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: AudioFormat.sttFormat,
            frameCapacity: AVAudioFrameCount(
                Double(inputBuffer.frameLength) * AudioFormat.sttFormat.sampleRate / inputBuffer.format.sampleRate
            )
        )

        guard let outputBuffer = outputBuffer else {
            logger.error("Could not allocate output buffer")
            return
        }

        var error: NSError?
        var inputFed = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputFed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputFed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error {
            logger.error("Conversion error: \(error?.localizedDescription ?? "unknown")")
            return
        }

        if outputBuffer.frameLength > 0 {
            continuation?.yield(outputBuffer)
        }
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
