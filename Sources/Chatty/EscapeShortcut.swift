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

    var isRegistered: Bool { hotKey != nil }

    func start() throws {
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
        guard installStatus == noErr else { throw HotkeyError(operation: "install Escape handler", status: installStatus) }

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
            throw HotkeyError(operation: "register Escape shortcut", status: registerStatus)
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
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    let shortcut = Unmanaged<EscapeShortcut>.fromOpaque(userData).takeUnretainedValue()

    // Only handle our own hotkey; let other hotkeys fall through the handler chain.
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }

    Task { @MainActor in shortcut.fire() }
    return noErr
}

private func fourCharCode(_ string: String) -> OSType {
    precondition(string.utf8.count == 4)
    return string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}
