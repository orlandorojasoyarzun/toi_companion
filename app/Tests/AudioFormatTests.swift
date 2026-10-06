import XCTest
import AVFoundation
@testable import ToiCompanion

/// Tests for AudioFormat — the canonical 16 kHz mono Float32 format used
/// by the STT pipeline.
final class AudioFormatTests: XCTestCase {

    func testSttFormat_sampleRate() {
        XCTAssertEqual(AudioFormat.sttFormat.sampleRate, 16_000)
    }

    func testSttFormat_mono() {
        XCTAssertEqual(AudioFormat.sttFormat.channelCount, 1)
    }

    func testSttFormat_isFloat32() {
        XCTAssertEqual(AudioFormat.sttFormat.commonFormat, .pcmFormatFloat32)
    }

    func testSttFormat_isNotInterleaved() {
        // Non-interleaved (planar) Float32 is what SpeechAnalyzer wants.
        XCTAssertFalse(AudioFormat.sttFormat.isInterleaved)
    }

    func testSttFormat_isStandard() {
        // Apple-marketed "standard" rate: 16 kHz is one of them.
        XCTAssertTrue(AudioFormat.sttFormat.isStandard)
    }
}
