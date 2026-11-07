import AppKit

@main
@MainActor
final class PasteTarget: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    static func main() {
        let app = NSApplication.shared
        let delegate = PasteTarget()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            edit.submenu!.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        menu.addItem(edit)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 600, height: 300),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Chatty Paste Destination"
        let editor = NSTextView(frame: window.contentView!.bounds)
        editor.autoresizingMask = [.width, .height]
        editor.isRichText = false
        editor.setAccessibilityIdentifier("paste.destination")
        window.contentView = editor
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
    }
}
