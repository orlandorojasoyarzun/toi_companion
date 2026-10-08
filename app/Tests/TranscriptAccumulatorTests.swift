import XCTest
@testable import ToiCompanion

/// Tests for `TranscriptAccumulator` — the pure reconciliation logic
/// that folds interim and final recognition results into a single
/// displayable string.
///
/// Apple's SFSpeechRecognizer delivers each result's
/// `bestTranscription.formattedString` as the COMPLETE best hypothesis
/// from the start of audio (not a delta). The accumulator must fold
/// these correctly so the UI always shows the best current guess.
final class TranscriptAccumulatorTests: XCTestCase {

    // MARK: - Initial state

    func testInitialState_isEmpty() {
        let acc = TranscriptAccumulator()
        XCTAssertEqual(acc.currentText, "")
        XCTAssertTrue(acc.isEmpty)
    }

    // MARK: - Interims only

    func testSingleInterim_replacesVolatile() {
        var acc = TranscriptAccumulator()
        acc.ingest(text: "hello", isFinal: false)
        XCTAssertEqual(acc.currentText, "hello")
        XCTAssertFalse(acc.isEmpty)
    }

    func testConsecutiveInterims_latestWins() {
        // The recognizer revises its hypothesis as more audio arrives.
        // The most recent interim is the best current guess.
        var acc = TranscriptAccumulator()
        acc.ingest(text: "the", isFinal: false)
        acc.ingest(text: "the quick", isFinal: false)
        acc.ingest(text: "the quick brown", isFinal: false)
        XCTAssertEqual(acc.currentText, "the quick brown")
    }

    func testEmptyInterim_doesNotClearPrevious() {
        // Some recognizers briefly emit empty strings during silence.
        // We must NOT clear previously-displayed text on an empty interim.
        var acc = TranscriptAccumulator()
        acc.ingest(text: "hello", isFinal: false)
        acc.ingest(text: "", isFinal: false)
        XCTAssertEqual(acc.currentText, "hello")
    }

    // MARK: - Finals

    func testFinal_replacesVolatileAndClearsInterim() {
        // A final result subsumes any prior interim (the recognizer
        // is saying "this part of the text is now stable").
        var acc = TranscriptAccumulator()
        acc.ingest(text: "hello w", isFinal: false)
        acc.ingest(text: "hello world", isFinal: true)
        XCTAssertEqual(acc.currentText, "hello world")
    }

    func testFinalWithPriorPfinalised_accumulates() {
        // After a final, the user keeps talking. A new final arrives
        // that contains BOTH the previous final AND the new words.
        var acc = TranscriptAccumulator()
        acc.ingest(text: "the quick brown", isFinal: true)
        acc.ingest(text: "the quick brown fox", isFinal: true)
        XCTAssertEqual(acc.currentText, "the quick brown fox")
    }

    // MARK: - Interims after finals

    func testInterimAfterFinal_appends() {
        // After a final, the user keeps talking. New interims should
        // appear after the finalised text.
        var acc = TranscriptAccumulator()
        acc.ingest(text: "hello", isFinal: true)
        acc.ingest(text: "hello world", isFinal: false)
        XCTAssertEqual(acc.currentText, "hello world")
    }

    func testFinalAfterInterimAfterFinal_accumulates() {
        // The full lifecycle: interims build up, become a final, more
        // interims, another final.
        var acc = TranscriptAccumulator()
        acc.ingest(text: "the quick brown", isFinal: false)
        acc.ingest(text: "the quick brown fox", isFinal: true)
        acc.ingest(text: "the quick brown fox jumps", isFinal: false)
        acc.ingest(text: "the quick brown fox jumps over", isFinal: true)
        XCTAssertEqual(acc.currentText, "the quick brown fox jumps over")
    }

    // MARK: - Reset

    func testReset_clearsBoth() {
        var acc = TranscriptAccumulator()
        acc.ingest(text: "hello", isFinal: true)
        acc.ingest(text: "hello world", isFinal: false)
        XCTAssertFalse(acc.isEmpty)
        acc.reset()
        XCTAssertTrue(acc.isEmpty)
        XCTAssertEqual(acc.currentText, "")
    }

    // MARK: - Equatable

    func testEquatable_sameStateIsEqual() {
        var a = TranscriptAccumulator()
        var b = TranscriptAccumulator()
        a.ingest(text: "hi", isFinal: false)
        b.ingest(text: "hi", isFinal: false)
        XCTAssertEqual(a, b)
    }

    func testEquatable_differentVolatileIsNotEqual() {
        var a = TranscriptAccumulator()
        var b = TranscriptAccumulator()
        a.ingest(text: "hi", isFinal: false)
        b.ingest(text: "bye", isFinal: false)
        XCTAssertNotEqual(a, b)
    }
}