#if CHATTY_DEBUG_PANEL
import Carbon.HIToolbox

/// Delivers a Carbon hotkey event to this app's installed handlers. This tests
/// registration and dispatch without synthesizing a keypress into another app.
@MainActor
enum DebugHotkeyEvent {
    static func send(id: UInt32) throws {
        guard id == 1 || id == 2 else { throw DebugInputError.injected("Hotkey id must be 1 (Escape) or 2 (recording)") }
        var event: EventRef?
        var status = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
        guard status == noErr, let event else { throw HotkeyError(operation: "create test hotkey event", status: status) }
        defer { ReleaseEvent(event) }
        var hotkey = EventHotKeyID(signature: 0x43485459, id: id)
        status = SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   MemoryLayout<EventHotKeyID>.size, &hotkey)
        guard status == noErr else { throw HotkeyError(operation: "set test hotkey id", status: status) }
        status = SendEventToEventTarget(event, GetApplicationEventTarget())
        guard status == noErr else { throw HotkeyError(operation: "dispatch test hotkey", status: status) }
    }
}
#endif
