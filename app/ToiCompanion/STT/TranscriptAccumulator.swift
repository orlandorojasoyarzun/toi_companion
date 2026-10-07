/// Pure reconciliation state for a single push-to-talk utterance.
///
/// Apple's `SFSpeechRecognizer` (and, in macOS 26+, `SpeechAnalyzer`
/// with `.volatileResults`) delivers a sequence of results, each of
/// which contains the *complete* best hypothesis from the start of
/// audio. Results come in two flavours:
///
/// - **interim** (`isFinal == false`): the volatile hypothesis;
///   later results may rewrite earlier words.
/// - **final**   (`isFinal == true`):  immutable; this text will
///   never change for this utterance.
///
/// `currentText` is the best displayable text at any moment: the
/// finalised text, with the latest interim appended if non-empty.
///
/// This type has no system dependencies and is exhaustively unit-tested
/// in `TranscriptAccumulatorTests`.
struct TranscriptAccumulator: Equatable {

    /// The immutable finalised text, accumulated across all
    /// `isFinal == true` results seen so far.
    private(set) var finalizedText: String = ""

    /// The most recent volatile (interim) text. May be rewritten by
    /// a later interim result, or cleared when a final arrives.
    private(set) var volatileText: String = ""

    init() {}

    /// The text to show in the UI right now.
    var currentText: String {
        finalizedText + volatileText
    }

    /// True iff we have any text at all (finalised or interim).
    var isEmpty: Bool {
        finalizedText.isEmpty && volatileText.isEmpty
    }

    /// Fold a new recognition result into the accumulator.
/// - Parameters:
///   - text:    `result.bestTranscription.formattedString` (or
///              the equivalent from a SpeechAnalyzer result).
///              SFSpeechRecognizer always returns the CUMULATIVE best
///              hypothesis from time zero, never a delta. We have to
///              strip the finalised prefix when an interim arrives
///              after a final.
///   - isFinal: `result.isFinal` for SFSpeechRecognizer; for
///              SpeechAnalyzer this maps from the volatile flag.
mutating func ingest(text: String, isFinal: Bool) {
    if isFinal {
        finalizedText = text
        volatileText = ""
        return
    }

    // Interim result: never overwrite a non-empty interim with an
    // empty one. The recognizer can briefly emit "" during silence
    // before it has formed any words.
    if text.isEmpty {
        return
    }

    if !finalizedText.isEmpty && text.hasPrefix(finalizedText) {
        // Interim extends the finalised text. Strip the finalised
        // prefix so we display only the new delta.
        let dropCount = finalizedText.count
        let idx = text.index(text.startIndex, offsetBy: dropCount)
        volatileText = String(text[idx...])
    } else {
        // Either there's no final yet, or the interim rewrote the
        // finalised text (unusual but possible). Show the interim
        // wholesale as the best current hypothesis.
        volatileText = text
    }
}

    /// Reset to empty — call at the start of each push-to-talk.
    mutating func reset() {
        finalizedText = ""
        volatileText = ""
    }
}