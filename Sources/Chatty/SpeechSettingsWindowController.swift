import AppKit

@MainActor
final class SpeechSettingsWindowController: NSWindowController {
    private let engine = NSPopUpButton()
    private let modelStatus = NSTextField(wrappingLabelWithString: "Checking local model…")
    private let progress = NSProgressIndicator()
    private let download = NSButton(title: "Download Model", target: nil, action: nil)
    private let error = NSTextField(wrappingLabelWithString: "")
    private let recognizer: LocalSpeechRecognizer
    private let onSave: (SpeechRecognitionEngine) throws -> Void
    private var observation: Task<Void, Never>?
    private var modelPhase: LocalSpeechRecognizer.ModelState.Phase = .notDownloaded

    init(recognizer: LocalSpeechRecognizer, onSave: @escaping (SpeechRecognitionEngine) throws -> Void) {
        self.recognizer = recognizer; self.onSave = onSave
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 370),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Speech Recognition"
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.setAccessibilitySubrole(.floatingWindow)
        super.init(window: panel)
        engine.addItems(withTitles: SpeechRecognitionEngine.allCases.map(\.title))
        engine.setAccessibilityLabel("Speech recognition engine")
        modelStatus.setAccessibilityLabel("Local model status")
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 1
        progress.setAccessibilityLabel("Model download progress")
        download.setAccessibilityLabel("Download local model")
        download.target = self; download.action = #selector(downloadClicked)
        let title = NSTextField(labelWithString: "Speech recognition")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString:
            "Apple recognition is the default. Nemotron 600M transcribes English locally as you speak, using a one-time download of approximately 626 MB. Both recognize on this Mac; sentence cleanup still uses your configured cleanup service. Changes apply to the next dictation."
        )
        help.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        let save = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        save.keyEquivalent = "\r"
        for button in [download, cancel, save] { button.bezelStyle = .rounded }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [spacer, cancel, save]); actions.spacing = 8
        error.textColor = .systemRed; error.setAccessibilityLabel("Speech settings validation")
        let content = NSStackView(views: [title, help, engine, modelStatus, progress, download, error, actions])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -20)
        ])
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        panel.center()
        observation = Task { [weak self, recognizer] in
            for await state in await recognizer.changes() { self?.update(state) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(engine: SpeechRecognitionEngine) {
        self.engine.selectItem(withTitle: engine.title)
        error.stringValue = ""
        showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    private func update(_ state: LocalSpeechRecognizer.ModelState) {
        modelPhase = state.phase
        modelStatus.stringValue = state.message
        modelStatus.textColor = state.phase == .failed ? .systemRed : .secondaryLabelColor
        download.isEnabled = state.phase != .preparing && state.phase != .ready
        switch state.phase {
        case .notDownloaded: download.title = "Download Model"
        case .preparing: download.title = "Preparing Model…"
        case .ready: download.title = "Model Ready"
        case .downloaded: download.title = "Load Downloaded Model"
        case .failed: download.title = "Retry Download / Load"
        }
        if let value = state.progress { progress.isIndeterminate = false; progress.doubleValue = value }
        else { progress.isIndeterminate = true }
        if state.phase == .preparing { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }
    @objc private func downloadClicked() {
        error.stringValue = ""
        Task { do { try await recognizer.prepare(allowDownload: true) } catch { /* Model state displays the failure and Retry. */ } }
    }
    @objc private func saveClicked() {
        let selected = SpeechRecognitionEngine.allCases[engine.indexOfSelectedItem]
        if selected == .nemotron && modelPhase != .ready && modelPhase != .downloaded {
            error.stringValue = "Download and prepare the local model before selecting Nemotron."
            return
        }
        do { try onSave(selected); close() }
        catch { self.error.stringValue = error.localizedDescription }
    }
    @objc private func cancelClicked() { close() }
}
