import AppKit
import ApplicationServices
import CoreFoundation
import CoreGraphics
import Foundation

/// Global hotkey monitor (fn / right-modifier hold-to-talk) via a listen-only CGEventTap.
/// Requires Accessibility trust; `start()` throws a descriptive error otherwise.
/// Reads `settings.dictationKey` / `settings.commandKey` live on every event, so
/// changing them in Settings takes effect immediately -- no config-change
/// notification needed.
@MainActor
final class HotkeyMonitor: HotkeyServiceProtocol {
    var onDictationKeyDown: (() -> Void)?
    var onDictationKeyUp: (() -> Void)?
    private(set) var lastEventUptime: TimeInterval?
    var onCommandKeyDown: (() -> Void)?
    var onCommandKeyUp: (() -> Void)?
    var onEscape: (() -> Void)?
    private(set) var isRunning = false

    private let settings: SettingsStore

    // Manipulated only on the main thread (start/stop/deinit); the escape hatch
    // lets `deinit` (which Swift treats as nonisolated) tear them down safely.
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?

    /// One down/up tracker per physical modifier key we can ever be asked to watch.
    /// Keyed alongside its HotkeyChoice so we can look up the live dictation/command
    /// role assignment at dispatch time.
    private var trackers: [(choice: HotkeyChoice, tracker: ModifierKeyTracker)] = []

    private static let escapeKeyCode: CGKeyCode = 53 // kVK_Escape

    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()

    init(settings: SettingsStore) {
        self.settings = settings
        resetTrackers()
    }

    deinit {
        // Mirrors stop(), but deinit can't call an isolated method directly.
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    func start() throws {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            throw HotkeyMonitorError.accessibilityNotTrusted
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: murmurHotkeyTapCallback,
            userInfo: selfPtr
        ) else {
            throw HotkeyMonitorError.tapCreationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw HotkeyMonitorError.tapCreationFailed
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        resetTrackers() // clean down/up state for this run
        isRunning = true
        Log.hotkey.info("HotkeyMonitor started (listen-only tap installed)")
    }

    func stop() {
        guard isRunning else { return }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        resetTrackers()
        isRunning = false
        Log.hotkey.info("HotkeyMonitor stopped")
    }

    private func resetTrackers() {
        trackers = HotkeyChoice.allCases.map {
            (choice: $0, tracker: ModifierKeyTracker(watchedKeyCode: $0.keyCode, deviceBitMask: $0.deviceBitMask))
        }
    }

    // MARK: - Tap callback entry point (invoked via murmurHotkeyTapCallback, main thread)

    /// `fileprivate` (not `private`): called from the free C-callback function below,
    /// which lives in this file but isn't an extension of this type.
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // CRITICAL: the system disables a tap after a timeout or suspicious user
        // input; without re-enabling here the hotkey would die silently until
        // the app is relaunched.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            Log.hotkey.warning("event tap disabled (\(String(describing: type))); re-enabled")
            return nil
        }

        let keyCode = CGKeyCode(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        lastEventUptime = EventUptime.seconds(fromEventTimestamp: event.timestamp)
        defer { lastEventUptime = nil }
        switch type {
        case .flagsChanged:
            handleFlagsChanged(keyCode: keyCode, rawFlags: event.flags.rawValue)
        case .keyDown:
            handleKeyDown(keyCode: keyCode)
        default:
            break
        }
        // Listen-only: the return value is ignored by the system, but hand back
        // the same (borrowed) event for a clean pass-through.
        return Unmanaged.passUnretained(event)
    }

    private func handleFlagsChanged(keyCode: CGKeyCode, rawFlags: UInt64) {
        for index in trackers.indices {
            guard let transition = trackers[index].tracker.consume(keyCode: keyCode, rawFlags: rawFlags) else { continue }
            dispatch(choice: trackers[index].choice, transition: transition)
            return // a flagsChanged event corresponds to exactly one physical key
        }
        // Unwatched key (e.g. left-side modifier, shift, caps lock) -- ignore.
    }

    private func handleKeyDown(keyCode: CGKeyCode) {
        if keyCode == Self.escapeKeyCode {
            onEscape?()
        }
    }

    /// Maps a physical-key transition to the dictation/command callbacks based on
    /// the *live* settings. If both roles are assigned to the same key, dictation wins.
    private func dispatch(choice: HotkeyChoice, transition: ModifierKeyTracker.Transition) {
        if choice == settings.dictationKey {
            switch transition {
            case .down: onDictationKeyDown?()
            case .up: onDictationKeyUp?()
            }
        } else if choice == settings.commandKey {
            switch transition {
            case .down: onCommandKeyDown?()
            case .up: onCommandKeyUp?()
            }
        }
    }
}

enum HotkeyMonitorError: LocalizedError {
    case accessibilityNotTrusted
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return L10n.string("error.hotkey.accessibility")
        case .tapCreationFailed:
            return L10n.string("error.hotkey.tapFailed")
        }
    }
}

// MARK: - ModifierKeyTracker (pure logic, unit-testable without CGEvent/AX)

/// Converts a stream of flagsChanged (keyCode, rawFlags) samples into clean
/// down/up transitions for ONE watched physical key, with no repeats.
///
/// `deviceBitMask` is tested directly against the event's raw flags -- for `fn`
/// this is the standard `CGEventFlags.maskSecondaryFn` bit; for right-side
/// modifiers it's the legacy per-device NX_DEVICE bit (distinct from the shared
/// `.maskCommand`/`.maskAlternate`/`.maskControl` bits, which stay set as long as
/// *either* the left or right physical key is held -- e.g. holding both left+right
/// Cmd and releasing only the right one must still report "up" for a right-Cmd
/// tracker even though `.maskCommand` remains set because left Cmd is still down).
struct ModifierKeyTracker: Equatable {
    enum Transition: Equatable {
        case down
        case up
    }

    let watchedKeyCode: CGKeyCode
    let deviceBitMask: UInt64
    private(set) var isDown = false

    init(watchedKeyCode: CGKeyCode, deviceBitMask: UInt64) {
        self.watchedKeyCode = watchedKeyCode
        self.deviceBitMask = deviceBitMask
    }

    /// Feed one (keyCode, rawFlags) sample. Returns nil if the keyCode isn't the
    /// one this tracker watches, or if the down/up state didn't actually change.
    mutating func consume(keyCode: CGKeyCode, rawFlags: UInt64) -> Transition? {
        guard keyCode == watchedKeyCode else { return nil }
        let nowDown = (rawFlags & deviceBitMask) != 0
        guard nowDown != isDown else { return nil }
        isDown = nowDown
        return nowDown ? .down : .up
    }
}

/// Legacy NX_DEVICE-style raw flag bits, still populated by CGEventTap-level
/// flagsChanged events and the only reliable way to discriminate left vs. right
/// modifier keys (see ModifierKeyTracker doc comment).
extension HotkeyChoice {
    var deviceBitMask: UInt64 {
        switch self {
        case .fn: return CGEventFlags.maskSecondaryFn.rawValue
        case .rightCommand: return 0x0010
        case .rightOption: return 0x0040
        case .rightControl: return 0x2000
        }
    }
}

// MARK: - C callback

/// Must be a context-free function (no captures) to satisfy `@convention(c)`;
/// `self` travels through `refcon`. The mach port source is added to the MAIN
/// run loop, so this runs synchronously on the main thread -- `assumeIsolated`
/// is a true statement here, not a workaround.
private func murmurHotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        monitor.handleTapEvent(type: type, event: event)
    }
}
