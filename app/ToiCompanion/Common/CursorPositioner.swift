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

    /// Returns an origin (bottom-left corner) for the sticky note panel
    /// anchored at the **top-right corner of the screen, just below the
    /// menu bar** — the visual "home base" next to the status icon.
    /// Used for the initial greeting on launch and for every subsequent
    /// `show()` call, so the note always reappears in the same
    /// predictable spot, even after the user dragged it elsewhere.
    ///
    /// `statusItemFrame` is only used to figure out which screen the
    /// menu bar lives on (so the panel follows the menu bar across
    /// multiple displays, not just the main one). The X/Y of the
    /// frame itself is intentionally NOT used — the status bar's
    /// window uses a flipped coordinate system internally and
    /// `convert(_:to: nil)` lands the frame at roughly (0, 0),
    /// which would put the panel in the bottom-left of the screen.
    /// Anchoring to the screen's top-right is robust regardless.
    func computeOriginBelowMenuBar(statusItemFrame: NSRect) -> Position {
        // Find the screen the menu bar is on. If the frame is
        // degenerate (button not yet laid out, etc.) just use the
        // main screen.
        let screen: NSScreen
        if statusItemFrame.width > 0 && statusItemFrame.height > 0 {
            let iconCenter = NSPoint(
                x: statusItemFrame.midX,
                y: statusItemFrame.midY
            )
            screen = NSScreen.screens.first { s in
                let f = s.frame
                return iconCenter.x >= f.minX && iconCenter.x <= f.maxX
                    && iconCenter.y >= f.minY && iconCenter.y <= f.maxY
            } ?? NSScreen.main ?? NSScreen.screens.first!
        } else {
            screen = NSScreen.main ?? NSScreen.screens.first!
        }
        // `visibleFrame` already excludes the menu bar, so `maxY` is
        // the bottom of the menu bar — the top edge of the usable
        // screen area. A `margin`-point gap keeps the panel from
        // touching either the menu bar above or the right edge.
        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 20
        let originX = screenFrame.maxX - panelWidth - margin
        let originY = screenFrame.maxY - panelHeight - margin

        return Position(x: originX, y: originY)
    }
}
