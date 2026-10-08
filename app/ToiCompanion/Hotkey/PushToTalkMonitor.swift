import AppKit
import CoreGraphics
import os.log

/// Listens for press/release of a single key (Right Shift dev / Right Option prod)
/// using a `CGEvent` tap in `.listenOnly` mode.
///
/// Lifecycle:
///   - `start()` installs the tap and registers its run loop source.
///   - `stop()` tears it down.
///   - On `tapDisabledByTimeout` / `tapDisabledByUserInput` we re-arm by
///     tearing down AND recreating the tap — a simple `tapEnable` flip
///     is not enough on macOS 15 once the tap has been disabled. The
///     `rearm()` method is the only place that rebuilds the CFMachPort.
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
        installTap()
    }

    /// Tears down the tap and re-creates it from scratch. Used when
    /// macOS sends a `tapDisabledBy*` event — `CGEvent.tapEnable(true)`
    /// alone is not enough on macOS 15; the underlying CFMachPort
    /// appears to be in a half-broken state after the disable and
    /// refuses to deliver any further events. Recreating the tap is
    /// the only reliable re-arm.
    private func rearm() {
        NSLog("toi_companion: PushToTalk re-arming (tear down + recreate)")
        teardownTap()
        installTap()
    }

    private func installTap() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap:    .cgSessionEventTap,
            place:  .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: PushToTalkMonitor.cgEventCallback,
            userInfo: userInfo
        ) else {
            NSLog("toi_companion: PushToTalk FAILED to create CGEvent tap — macOS is denying it (cdhash / TCC / sandbox issue)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        NSLog("toi_companion: PushToTalkMonitor installed for \(key.displayName) (keycode=\(key.rawValue))")
    }

    private func teardownTap() {
        guard let tap = eventTap, let source = runLoopSource else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.eventTap = nil
        self.runLoopSource = nil
    }

    /// Removes the tap and the run loop source.
    func stop() {
        teardownTap()
        NSLog("toi_companion: PushToTalkMonitor stopped")
    }

    // MARK: - Callback

    /// C-function trampoline. For `.listenOnly` taps we return the event
    /// unchanged so macOS keeps delivering events to us. The Swift bridge
    /// auto-wraps `event` in `Unmanaged` for us.
    private static let cgEventCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<PushToTalkMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handleEvent(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        // Re-arm the tap if macOS disabled it. The simple re-enable that
        // earlier versions of this file used is unreliable on macOS 15;
        // we tear down and recreate the tap instead.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            NSLog("toi_companion: PushToTalk tap disabled (type=\(type.rawValue)) — recreating")
            DispatchQueue.main.async { [weak self] in
                self?.rearm()
            }
            return
        }

        guard type == .flagsChanged else { return }

        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        NSLog("toi_companion: PushToTalk flagsChanged keycode=\(keycode) expected=\(self.key.rawValue) flags=\(flags.rawValue) pressed=\(flags.contains(self.key.pressedFlag))")
        guard keycode == self.key.rawValue else { return }

        let nowPressed = flags.contains(self.key.pressedFlag)
        guard nowPressed != isPressed else { return }
        isPressed = nowPressed

        // Hop to the main thread so the delegate can touch UI safely.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if nowPressed {
                NSLog("toi_companion: PushToTalk \(self.key.displayName) PRESSED")
                self.delegate?.pushToTalkDidPress()
            } else {
                NSLog("toi_companion: PushToTalk \(self.key.displayName) RELEASED")
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
