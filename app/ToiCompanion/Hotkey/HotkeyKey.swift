import AppKit
import CoreGraphics

/// Identifies a single key on the keyboard by its hardware keycode.
/// We use keycodes (not NSEvent.modifierFlags) because modifier flags
/// combine left+right (e.g. `.shift` is true when EITHER shift is down).
/// Keycodes are hardware-level and stable across keyboard layouts.
enum HotkeyKey: Int, CaseIterable {
    /// Right Shift — keycode 60. Used during development because it
    /// doesn't conflict with AltGr characters on Latin keyboards.
    case rightShift  = 60
    /// Right Option — keycode 61. The final v1.0 hotkey.
    case rightOption = 61

    /// Human-readable name for logs and the menu.
    var displayName: String {
        switch self {
        case .rightShift:  return "Right Shift"
        case .rightOption: return "Right Option"
        }
    }

    /// The `CGEventFlags` bit that is set while this key is held down.
    /// `.maskShift` covers both shifts, but the keycode filter already
    /// narrows to the right one, so this is just for confirmation.
    var pressedFlag: CGEventFlags {
        switch self {
        case .rightShift:  return .maskShift
        case .rightOption: return .maskAlternate
        }
    }
}
