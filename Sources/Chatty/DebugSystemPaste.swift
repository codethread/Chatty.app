#if CHATTY_DEBUG_PANEL
import AppKit

/// An explicit, one-shot desktop integration check. Clipboard data stays in
/// memory and is restored after the destination has been inspected.
@MainActor
final class DebugSystemPaste {
    private(set) var target: NSRunningApplication?
    private var backup: [NSPasteboardItem]?
    private var stagedChangeCount: Int?
    private(set) var restoredClipboard = false
    private(set) var pendingDispatch = false
    private(set) var dispatchCount = 0
    var targetID: String? { target?.bundleIdentifier }
    var needsRestore: Bool { backup != nil }

    func arm(bundleID: String?) throws {
        guard backup == nil else { throw DebugInputError.injected("Restore the test clipboard before another system paste") }
        let destination = bundleID.map { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            ?? NSWorkspace.shared.frontmostApplication
        guard let app = destination,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw DebugInputError.injected("Choose a running external test destination before arming system paste")
        }
        target = app
    }

    func stage(_ text: String) throws -> NSRunningApplication {
        let app = target!
        target = nil
        let pasteboard = NSPasteboard.general
        let saved = try (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw DebugInputError.injected("Could not preserve the clipboard's \(type.rawValue) representation")
                }
                copy.setData(data, forType: type)
            }
            return copy
        }
        backup = saved
        pendingDispatch = true
        restoredClipboard = false
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        stagedChangeCount = pasteboard.changeCount
        return app
    }

    func finishDispatch(posted: Bool) {
        pendingDispatch = false
        if posted { dispatchCount += 1 }
    }

    func restore() throws {
        guard !pendingDispatch else { throw DebugInputError.injected("Wait for the system paste dispatch before restoring the clipboard") }
        target = nil
        guard let saved = backup else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == stagedChangeCount else {
            backup = nil
            stagedChangeCount = nil
            throw DebugInputError.injected("The clipboard changed after the test; its newer contents were kept")
        }
        pasteboard.clearContents()
        let written = saved.isEmpty || pasteboard.writeObjects(saved)
        stagedChangeCount = pasteboard.changeCount
        if !written {
            throw DebugInputError.injected("Could not restore the test clipboard")
        }
        let actual = pasteboard.pasteboardItems ?? []
        guard saved.count == actual.count, zip(saved, actual).allSatisfy({ original, current in
            Set(original.types) == Set(current.types) && original.types.allSatisfy { original.data(forType: $0) == current.data(forType: $0) }
        }) else { throw DebugInputError.injected("Clipboard restoration did not preserve every representation") }
        restoredClipboard = true
        backup = nil
        stagedChangeCount = nil
    }
}
#endif
