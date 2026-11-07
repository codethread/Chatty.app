import AppKit
import Carbon.HIToolbox

@MainActor
final class DoubleShiftShortcut {
    private let action: () -> Void
    private var monitor: Any?
    private var gesture = DoubleShiftGesture()

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        gesture = DoubleShiftGesture()
    }

    private func handle(event: NSEvent) {
        if gesture.consume(keyCode: event.keyCode, flags: event.modifierFlags, time: event.timestamp) { action() }
    }
}

struct DoubleShiftGesture {
    private var lastRelease: TimeInterval?

    mutating func consume(keyCode: UInt16, flags: NSEvent.ModifierFlags, time: TimeInterval) -> Bool {
        guard flags.intersection([.command, .control, .option]).isEmpty else {
            lastRelease = nil
            return false
        }
        guard Int(keyCode) == kVK_Shift, !flags.contains(.shift) else { return false }
        if let lastRelease, time - lastRelease <= Settings.doubleTapInterval {
            self.lastRelease = nil
            return true
        }
        lastRelease = time
        return false
    }
}
