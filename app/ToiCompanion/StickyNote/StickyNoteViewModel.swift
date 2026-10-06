import Foundation
import os.log

/// Observable state for the sticky note.
/// Phase 1: only text and visibility.
/// Later: streamingProgress, isProcessing, etc.
@MainActor
final class StickyNoteViewModel: ObservableObject {

    private let logger = Logger(subsystem: "com.salem.toicompanion", category: "StickyNoteViewModel")

    @Published var text: String = ""
    @Published var isVisible: Bool = false

    /// Replaces the current text. Called by the SSE parser and STT as text arrives.
    func updateText(_ newText: String) {
        text = newText
    }

    /// Shows the note with optional initial text.
    func show(initialText: String = "...") {
        text = initialText
        isVisible = true
        logger.info("StickyNote shown: \(initialText)")
    }

    /// Hides the note immediately.
    func hide() {
        isVisible = false
        text = ""
        logger.info("StickyNote hidden")
    }
}
