import Cocoa
import Carbon.HIToolbox

/// Watches the keyboard system-wide for the fn (globe) key via a CGEvent tap.
/// Needs Accessibility permission; `start()` returns false until it's granted.
final class HotkeyMonitor {
    enum Event {
        case fnDown
        case fnUp
        /// Space pressed while fn is held: switch to hands-free mode.
        case fnSpace
        /// Some other key or modifier pressed while fn is held (fn+arrow, fn+F1…).
        case fnChord
        case escape
    }

    /// Called on the main thread for every event. Return true to swallow the key press
    /// so it doesn't reach the focused app (only honoured for fnSpace and escape).
    var handler: ((Event) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnHeld = false

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .flagsChanged:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == kVK_Function {
                let down = event.flags.contains(.maskSecondaryFn)
                guard down != fnHeld else { return pass }
                fnHeld = down
                _ = handler?(down ? .fnDown : .fnUp)
            } else if fnHeld {
                _ = handler?(.fnChord)
            }
            return pass

        case .keyDown:
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == kVK_Escape {
                return handler?(.escape) == true ? nil : pass
            }
            if fnHeld {
                if keyCode == kVK_Space {
                    return handler?(.fnSpace) == true ? nil : pass
                }
                _ = handler?(.fnChord)
            }
            return pass

        default:
            return pass
        }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
