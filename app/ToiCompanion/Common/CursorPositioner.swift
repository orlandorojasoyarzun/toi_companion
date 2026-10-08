import AppKit
import os.log

/// Positions the sticky note near the mouse cursor, clamped to the screen bounds.
/// Uses macOS global coordinate system (origin bottom-left).
struct CursorPositioner {

    private let logger = Logger(subsystem: "com.salem.toicompanion", category: "CursorPositioner")

    /// Fixed size of the sticky note panel.
    ///
    /// `panelWidth` is locked to `StickyNoteView.minPanelWidth` (340).
    /// If they're out of sync the SwiftUI body is wider than the NSPanel
    /// and the right edge of the content (including the ↲ button in the
    /// top bar) gets clipped by the panel's contentRect.
    let panelWidth: CGFloat = 340
    let panelHeight: CGFloat = 140

    /// Horizontal offset from the cursor to the note's left edge.
    private let xOffset: CGFloat = 30
    /// Vertical offset from the cursor to the note's bottom edge.
    private let yOffset: CGFloat = 20
    /// Minimum margin from screen edges.
    private let edgeMargin: CGFloat = 20

    struct Position {
        let x: CGFloat
        let y: CGFloat
    }

    /// Returns the origin (bottom-left corner) for the sticky note panel,
    /// positioned near the cursor and clamped to the screen that contains it.
    func computeOrigin() -> Position {
        let mouseLocation = NSEvent.mouseLocation

        // NSEvent.mouseLocation is in screen coordinates (origin bottom-left).
        // Find which screen contains the cursor.
        let screenContainingCursor = NSScreen.screens.first { screen in
            let frame = screen.frame
            return mouseLocation.x >= frame.minX
                && mouseLocation.x <= frame.maxX
                && mouseLocation.y >= frame.minY
                && mouseLocation.y <= frame.maxY
        }

        let screen = screenContainingCursor ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.visibleFrame
        logger.debug("Mouse at (\(mouseLocation.x), \(mouseLocation.y)), screen: \(screen.localizedName)")

        // Position the note to the right and above the cursor.
        var originX = mouseLocation.x + xOffset
        var originY = mouseLocation.y + yOffset

        // Clamp to screen bounds.
        originX = max(screenFrame.minX + edgeMargin,
                      min(originX, screenFrame.maxX - panelWidth - edgeMargin))
        originY = max(screenFrame.minY + edgeMargin,
                      min(originY, screenFrame.maxY - panelHeight - edgeMargin))

        return Position(x: originX, y: originY)
    }
}
