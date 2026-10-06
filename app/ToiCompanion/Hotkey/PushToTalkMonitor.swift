import AppKit
import CoreGraphics
import os.log

/// Listens for press/release of a single key (Right Shift dev / Right Option prod)
/// using a `CGEvent` tap in `.listenOnly` mode. Does NOT require Accessibility
/// permission because we never consume the events, only observe them.
///
/// Lifecycle:
///   - `start()` installs the tap and registers its run loop source.
///   - `stop()` tears it down.
///   - On `tapDisabledByTimeout` / `tapDisabledByUserInput` we re-arm automatically
///     so the user never has to restart the app.
final class PushToTalkMonitor {

    private let logger = AppLogger.make("PushToTalk")
    private let key: HotkeyKey

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    /// Set by AppDelegate. Called on the main thread.
    weak var delegate: PushToTalkMonitorDelegate?

    init(key: HotkeyKey) {
        self.key = key
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Installs the CGEvent tap. Idempotent: calling twice is a no-op.
    func start() {
        guard eventTap == nil else {
            logger.debug("PushToTalkMonitor already running")
            return
        }

        // We only want the flags-changed events: a single bit tells us
        // which modifier went down/up, plus the keycode tells us which one.
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        // The callback must be a C function — we use a trampoline that
        // forwards to the Swift instance stored in userInfo.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap:    .cgSessionEventTap,
            place:  .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: PushToTalkMonitor.cgEventCallback,
            userInfo: userInfo
        ) else {
            logger.error("Failed to create CGEvent tap. macOS may be denying it.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        let keyName = key.displayName
        logger.info("PushToTalkMonitor started for \(keyName)")
    }

    /// Removes the tap and the run loop source.
    func stop() {
        guard let tap = eventTap, let source = runLoopSource else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.eventTap = nil
        self.runLoopSource = nil
        logger.info("PushToTalkMonitor stopped")
    }

    // MARK: - Callback

    /// C-function trampoline. Pulls the Swift instance back out of `userInfo`
    /// and forwards the event. Returns nil because we never consume events.
    private static let cgEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo = userInfo else { return nil }
        let monitor = Unmanaged<PushToTalkMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handleEvent(type: type, event: event)
        return nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        // Re-arm the tap if macOS disabled it (timeout or user input).
        // Without this, the hotkey would silently die after a while.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            logger.warning("CGEvent tap disabled (\(type.rawValue)) — re-arming")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        guard type == .flagsChanged else { return }

        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keycode == key.rawValue else { return }

        let flags = event.flags
        let nowPressed = flags.contains(key.pressedFlag)

        guard nowPressed != isPressed else { return }
        isPressed = nowPressed

        // Hop to the main thread so the delegate can touch UI safely.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if nowPressed {
                self.logger.debug("\(self.key.displayName) pressed")
                self.delegate?.pushToTalkDidPress()
            } else {
                self.logger.debug("\(self.key.displayName) released")
                self.delegate?.pushToTalkDidRelease()
            }
        }
    }

    // MARK: - Pure helper (testable)

    /// Pure function: given a flags-changed event's keycode, flags, and the
    /// previous pressed state, returns the new pressed state. Extracted
    /// from the C callback so we can unit-test the press/release logic
    /// without actually installing a CGEvent tap.
    static func updatePressedState(
        for key: HotkeyKey,
        eventKeycode: Int,
        eventFlags: CGEventFlags,
        wasPressed: Bool
    ) -> Bool {
        guard eventKeycode == key.rawValue else { return wasPressed }
        return eventFlags.contains(key.pressedFlag)
    }
}

// MARK: - Delegate

protocol PushToTalkMonitorDelegate: AnyObject {
    @MainActor func pushToTalkDidPress()
    @MainActor func pushToTalkDidRelease()
}
