import Foundation
import os.log

/// Observable state for the sticky note.
@MainActor
final class StickyNoteViewModel: ObservableObject {

    private let logger = Logger(subsystem: "com.salem.toicompanion", category: "StickyNoteViewModel")

    @Published var text: String = ""
    @Published var isVisible: Bool = false

    /// True while the LLM stream is open. Drives the animated "…"
    /// streaming indicator and the cancel button.
    @Published var isStreaming: Bool = false

    /// True while the user is editing the transcript inline.
    /// When true, the SwiftUI body swaps the static `Text` for a
    /// `WrappedTextField` and the panel temporarily accepts key input.
    @Published var isEditing: Bool = false

    /// When the user drags the bottom-right resize grip to re-frame
    /// the note, this is the size they picked. nil means "no user
    /// override, use the default size".
    @Published var userSize: CGSize? = nil

    /// The panel's current content size, written by
    /// `StickyNotePanel.resizeToFit` after every `setFrame`. Not
    /// @Published — observing it would loop SwiftUI re-renders.
    var currentPanelSize: CGSize = CGSize(width: 0, height: 0)

    /// Replaces the current text. Called by the SSE parser and STT as text arrives.
    func updateText(_ newText: String) {
        text = newText
    }

    /// Shows the note with optional initial text. Also clears any
    /// in-progress edit so the next PTT session starts fresh.
    func show(initialText: String = "...") {
        text = initialText
        isVisible = true
        isEditing = false
        logger.info("StickyNote shown: \(initialText)")
    }

    /// Hides the note immediately.
    func hide() {
        isVisible = false
        text = ""
        isStreaming = false
        isEditing = false
        logger.info("StickyNote hidden")
    }
}
