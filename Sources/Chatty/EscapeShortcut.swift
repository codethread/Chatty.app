import AppKit
import Carbon.HIToolbox

@MainActor
final class EscapeShortcut {
    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func start() {
        guard hotKey == nil, handler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            escapeHotKeyHandler,
            1,
            &eventType,
            selfPointer,
            &handler
        )
        guard installStatus == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("CHTY"), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registerStatus == noErr else {
            stop()
            return
        }
    }

    func stop() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }

        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
    }

    fileprivate func fire() {
        action()
    }
}

private func escapeHotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let shortcut = Unmanaged<EscapeShortcut>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in shortcut.fire() }
    return noErr
}

private func fourCharCode(_ string: String) -> OSType {
    precondition(string.utf8.count == 4)
    return string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}
