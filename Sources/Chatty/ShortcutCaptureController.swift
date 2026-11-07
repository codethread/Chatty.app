import AppKit
import Carbon.HIToolbox

/// Modal-ish panel that records the next keychord the user presses.
/// Escape (with no modifiers) cancels; a chord including at least one modifier commits.
@MainActor
final class ShortcutCaptureController {
    private var panel: NSPanel?
    private var monitor: Any?
    private var completion: ((KeyBinding) -> Void)?
    private let hintLabel = NSTextField(labelWithString: "")
    #if CHATTY_DEBUG_PANEL
    var debugWindow: NSWindow? { panel }
    func injectKey(code: UInt16, modifiers: NSEvent.ModifierFlags, characters: String) throws {
        guard let panel else { throw DebugInputError.injected("Open shortcut capture first") }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        _ = handle(event)
    }
    #endif

    func begin(current: KeyBinding?, completion: @escaping (KeyBinding) -> Void) {
        guard panel == nil else { return }
        self.completion = completion

        let panel = makePanel(current: current)
        self.panel = panel

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifierless = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .isDisjoint(with: [.command, .control, .option, .shift])

        if Int(event.keyCode) == kVK_Escape && modifierless {
            finish(nil)
            return true
        }

        guard let binding = KeyBinding(event: event) else {
            hintLabel.stringValue = "Hold at least one of ⌘ ⌃ ⌥ ⇧, then a key."
            return true
        }

        finish(binding)
        return true
    }

    private func finish(_ binding: KeyBinding?) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        let completion = self.completion
        self.completion = nil
        if let binding { completion?(binding) }
    }

    private func makePanel(current: KeyBinding?) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 140),
            styleMask: [.titled, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Set Recording Shortcut"
        panel.level = .floating
        panel.hidesOnDeactivate = false

        let title = NSTextField(labelWithString: "Press the shortcut you want.")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let currentText = current.map { "Current: \($0.label)" } ?? "No shortcut set."
        let subtitle = NSTextField(labelWithString: currentText)
        subtitle.textColor = .secondaryLabelColor

        hintLabel.stringValue = "Escape cancels."
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [title, subtitle, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        panel.contentView = content
        return panel
    }
}
