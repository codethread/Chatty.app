import AppKit
import Carbon.HIToolbox

@MainActor
final class DoubleShiftShortcut {
    private let action: () -> Void
    private var monitor: Any?
    private var lastLeftShiftUp: TimeInterval = 0

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
        }
    }

    private func handle(event: NSEvent) {
        guard Int(event.keyCode) == kVK_Shift else { return } // left shift only
        let isDown = event.modifierFlags.contains(.shift)
        guard !isDown else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLeftShiftUp <= Settings.doubleTapInterval {
            lastLeftShiftUp = 0
            action()
        } else {
            lastLeftShiftUp = now
        }
    }
}
