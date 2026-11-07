#if CHATTY_DEBUG_PANEL
import AppKit

/// Automates the running app's actual controls and target/action handlers.
/// Labels are the same labels exposed to Accessibility and to a human tester.
@MainActor
enum DebugUI {
    struct Element: Codable {
        let label: String
        let type: String
        let value: String?
        let enabled: Bool?
    }
    struct Snapshot: Codable {
        let title: String
        let visible: Bool
        let controls: [Element]
    }

    static func snapshot(_ window: NSWindow) -> Snapshot {
        Snapshot(title: window.title, visible: window.isVisible, controls: views(window.contentView!).compactMap { view in
            guard let label = label(view), !label.isEmpty else { return nil }
            let value: String?
            switch view {
            case let popup as NSPopUpButton: value = popup.titleOfSelectedItem
            case let field as NSTextField: value = field.stringValue
            case let editor as NSTextView: value = editor.string
            default: value = nil
            }
            return Element(label: label, type: String(describing: type(of: view)), value: value, enabled: (view as? NSControl)?.isEnabled)
        })
    }

    static func interact(_ window: NSWindow, control: String, value: String?, click: Bool) throws {
        guard let view = views(window.contentView!).first(where: { label($0) == control }) else {
            throw DebugInputError.injected("No control named '\(control)' in \(window.title)")
        }
        if let value {
            switch view {
            case let popup as NSPopUpButton:
                guard popup.itemTitles.contains(value) else { throw DebugInputError.injected("Unknown popup choice") }
                popup.selectItem(withTitle: value)
                NSApp.sendAction(popup.action!, to: popup.target, from: popup)
            case let field as NSTextField where field.isEditable: field.stringValue = value
            case let editor as NSTextView where editor.isEditable:
                editor.string = value
                editor.didChangeText()
            default: throw DebugInputError.injected("Control is not editable")
            }
        }
        if click {
            guard let button = view as? NSButton, button.isEnabled else { throw DebugInputError.injected("Control is not an enabled button") }
            button.performClick(nil)
        }
        window.contentView!.layoutSubtreeIfNeeded()
    }

    private static func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private static func label(_ view: NSView) -> String? {
        if let label = view.accessibilityLabel(), !label.isEmpty { return label }
        if let button = view as? NSButton { return button.title }
        return nil
    }
}
#endif
