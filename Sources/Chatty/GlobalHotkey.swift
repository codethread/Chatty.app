import AppKit
import Carbon.HIToolbox

/// A single re-registerable global hotkey backed by Carbon `RegisterEventHotKey`.
/// Call `update(binding:)` to (re)bind or `update(binding: nil)` to unbind.
@MainActor
final class GlobalHotkey {
    nonisolated let id: UInt32
    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(id: UInt32, action: @escaping () -> Void) {
        self.id = id
        self.action = action
    }

    var isRegistered: Bool { hotKey != nil }

    func update(binding: KeyBinding?) throws {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard let binding else { return }

        if handler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let selfPointer = Unmanaged.passUnretained(self).toOpaque()
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                globalHotKeyHandler,
                1,
                &eventType,
                selfPointer,
                &handler
            )
            guard installStatus == noErr else { throw HotkeyError(operation: "install shortcut handler", status: installStatus) }
        }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("CHTY"), id: id)
        let registerStatus = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if registerStatus != noErr {
            hotKey = nil
            throw HotkeyError(operation: "register recording shortcut", status: registerStatus)
        }
    }

    fileprivate func fire() {
        action()
    }
}

private func globalHotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()

    // Every handler on the shared event target sees every hotkey press, so only
    // act on our own id and let the rest of the chain handle the others.
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
    guard status == noErr, hotKeyID.id == hotkey.id else { return OSStatus(eventNotHandledErr) }

    Task { @MainActor in hotkey.fire() }
    return noErr
}

private func fourCharCode(_ string: String) -> OSType {
    precondition(string.utf8.count == 4)
    return string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}
