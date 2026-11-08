import AppKit

@MainActor
final class CorrectionSettingsWindowController: NSWindowController {
    private let promptView = NSTextView()
    private let tapeEnabledButton = NSButton(checkboxWithTitle: "Enable for the tape instructions", target: nil, action: nil)
    private let tapePromptView = NSTextView()
    private let dictionaryView = NSTextView()
    private let contextLinesField = NSTextField(string: "3")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let onSave: (CorrectionSettings) throws -> Void

    init(onSave: @escaping (CorrectionSettings) throws -> Void) {
        self.onSave = onSave
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 800),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sentence Cleanup"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.contentMinSize = NSSize(width: 600, height: 740)
        super.init(window: panel)

        let title = NSTextField(labelWithString: "Sentence cleanup")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString:
            "Customize how dictated text is edited. Saved settings apply to subsequent correction requests."
        )
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        contextLinesField.setAccessibilityLabel("Context lines")
        contextLinesField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let contextRow = NSStackView(views: [label("Context lines"), contextLinesField])
        contextRow.spacing = 10
        let contextHelp = NSTextField(wrappingLabelWithString:
            "Send the last few wrapped transcript lines, expanded to whole sentences. All new completed speech is included; older corrected text stays fixed."
        )
        contextHelp.font = .systemFont(ofSize: 12)
        contextHelp.textColor = .secondaryLabelColor
        let promptLabel = label("Cleanup instructions")
        let dictionaryLabel = label("Word dictionary")
        let help = NSTextField(wrappingLabelWithString: "One mapping per line, for example jason = JSON. Matching ignores capitalization; preferred spellings keep their case.")
        help.font = .systemFont(ofSize: 12)
        help.textColor = .secondaryLabelColor

        let promptScroll = editor(promptView, name: "Cleanup instructions", monospaced: false)
        tapeEnabledButton.target = self
        tapeEnabledButton.action = #selector(tapeEnabledChanged)
        let tapeHelp = NSTextField(wrappingLabelWithString:
            "Customize spoken editing requests. Disable this section to keep those requests as dictated text. Only text within the supplied context can be edited."
        )
        tapeHelp.font = .systemFont(ofSize: 12)
        tapeHelp.textColor = .secondaryLabelColor
        let tapeScroll = editor(tapePromptView, name: "For the tape instructions", monospaced: false)
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
            title, description, contextRow, contextHelp, promptLabel, promptScroll,
            label("For the tape"), tapeEnabledButton, tapeHelp, tapeScroll, dictionaryLabel,
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
            promptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            tapeScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            dictionaryScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            promptScroll.heightAnchor.constraint(equalTo: dictionaryScroll.heightAnchor)
        ])
        for view in content.arrangedSubviews where view !== tapeEnabledButton {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(settings: CorrectionSettings) {
        promptView.string = settings.prompt
        tapeEnabledButton.state = settings.tapeEnabled ? .on : .off
        tapePromptView.string = settings.tapePrompt
        tapeEnabledChanged()
        dictionaryView.string = settings.dictionaryText
        contextLinesField.stringValue = String(settings.contextLines)
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
            let settings = try CorrectionSettings.parse(prompt: promptView.string, dictionaryText: dictionaryView.string,
                                                        contextLinesText: contextLinesField.stringValue,
                                                        tapeEnabled: tapeEnabledButton.state == .on,
                                                        tapePrompt: tapePromptView.string)
            try onSave(settings)
            close()
        } catch {
            errorLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func cancelClicked() { close() }

    @objc private func tapeEnabledChanged() {
        tapePromptView.isEditable = tapeEnabledButton.state == .on
        tapePromptView.textColor = tapePromptView.isEditable ? .textColor : .secondaryLabelColor
    }

    @objc private func resetClicked() {
        promptView.string = CorrectionSettings.defaultPrompt
        tapeEnabledButton.state = .on
        tapePromptView.string = CorrectionSettings.defaultTapePrompt
        tapeEnabledChanged()
        dictionaryView.string = ""
        contextLinesField.stringValue = String(CorrectionSettings.default.contextLines)
        errorLabel.stringValue = ""
    }
}
