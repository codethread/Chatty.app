import AppKit

@MainActor
final class CorrectionSettingsWindowController: NSWindowController {
    private let promptView = NSTextView()
    private let dictionaryView = NSTextView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let onSave: (CorrectionSettings) throws -> Void

    init(onSave: @escaping (CorrectionSettings) throws -> Void) {
        self.onSave = onSave
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sentence Cleanup"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.contentMinSize = NSSize(width: 560, height: 500)
        super.init(window: panel)

        let title = NSTextField(labelWithString: "Sentence cleanup")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString:
            "Customize how each sentence is edited. Saved settings apply to subsequent correction requests."
        )
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        let promptLabel = label("Cleanup instructions")
        let dictionaryLabel = label("Word dictionary")
        let help = NSTextField(wrappingLabelWithString: "One mapping per line, for example jason = JSON. Matching ignores capitalization; preferred spellings keep their case.")
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor

        let promptScroll = editor(promptView, name: "Cleanup instructions", monospaced: false)
        let dictionaryScroll = editor(dictionaryView, name: "Word dictionary", monospaced: true)
        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetClicked))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        for button in [reset, cancel, save] { button.bezelStyle = .rounded }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [reset, spacer, cancel, save])
        buttons.spacing = 8
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.setAccessibilityLabel("Settings validation")

        let content = NSStackView(views: [
            title, description, promptLabel, promptScroll, dictionaryLabel,
            help, dictionaryScroll, errorLabel, buttons
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -20),
            promptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            dictionaryScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            promptScroll.heightAnchor.constraint(equalTo: dictionaryScroll.heightAnchor)
        ])
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(settings: CorrectionSettings) {
        promptView.string = settings.prompt
        dictionaryView.string = settings.dictionaryText
        errorLabel.stringValue = ""
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func editor(_ view: NSTextView, name: String, monospaced: Bool) -> NSScrollView {
        view.isRichText = false
        view.font = monospaced ? .monospacedSystemFont(ofSize: 14, weight: .regular) : .systemFont(ofSize: 14)
        view.textContainerInset = NSSize(width: 8, height: 8)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer!.widthTracksTextView = true
        view.setAccessibilityLabel(name)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        return scroll
    }

    @objc private func saveClicked() {
        do {
            let settings = try CorrectionSettings.parse(prompt: promptView.string, dictionaryText: dictionaryView.string)
            try onSave(settings)
            close()
        } catch {
            errorLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func cancelClicked() { close() }

    @objc private func resetClicked() {
        promptView.string = CorrectionSettings.defaultPrompt
        dictionaryView.string = ""
        errorLabel.stringValue = ""
    }
}
