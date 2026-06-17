import AppKit
import Carbon.HIToolbox

final class DoubleShiftShortcut {
    private let action: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastLeftShiftUp: TimeInterval = 0

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func start() {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let shortcut = Unmanaged<DoubleShiftShortcut>.fromOpaque(refcon).takeUnretainedValue()
            shortcut.handle(event: event)
            return Unmanaged.passUnretained(event)
        }
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
    }

    private func handle(event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == kVK_Shift else { return } // left shift only
        let isDown = event.flags.contains(.maskShift)
        guard !isDown else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLeftShiftUp <= Settings.doubleTapInterval {
            lastLeftShiftUp = 0
            let action = action
            DispatchQueue.main.async(execute: action)
        } else {
            lastLeftShiftUp = now
        }
    }
}
