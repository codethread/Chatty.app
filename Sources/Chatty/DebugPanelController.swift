#if CHATTY_DEBUG_PANEL
import AppKit

@MainActor
final class DebugPanelController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let input: DebugDictationInputService
    private let controller: DictationController
    private let corrector: DebugTranscriptCorrector
    private let onSetAPIKey: () -> Void
    private let backend = NSPopUpButton()
    private let source = NSPopUpButton()
    private let prepareButton = NSButton(title: "Prepare local model", target: nil, action: nil)
    private let requestStatus = NSTextField(labelWithString: "Ready")
    private let requestLog = NSTextView()
    private var statusTimer: Timer?
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
    private let status = NSTextField(labelWithString: "Ready — enter text, then start dictation.")
    private let startButton = NSButton(title: "Start dictation", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop dictation", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let streamButton = NSButton(title: "Stream text", target: nil, action: nil)
    private let partialField = NSTextField(string: "")
    private let fakeBehavior = NSPopUpButton()
    private let fault = NSPopUpButton()
    private let historyPicker = NSPopUpButton()
    private var historyIDs: [UUID] = []
    private let harnessStatus = NSTextField(wrappingLabelWithString: "Starting isolated harness…")
    var harness: DebugHarness? {
        didSet {
            harness?.onChange = { [weak self] in self?.updateControls() }
            updateControls()
        }
    }

    init(input: DebugDictationInputService, controller: DictationController, corrector: DebugTranscriptCorrector,
         onSetAPIKey: @escaping () -> Void) {
        self.input = input
        self.controller = controller
        self.corrector = corrector
        self.onSetAPIKey = onSetAPIKey
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 920),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Chatty Debug Panel"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 760, height: 850)
        super.init(window: panel)
        panel.delegate = self

        let title = NSTextField(labelWithString: "Live dictation")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString:
            "Inject recognition snapshots, replay audio, or compare microphones using the real controllers and overlay. The local HTTP fake returns SCREAMING_SNAKE_CASE without a token. Debug recordings, settings, clipboard and paste target are isolated from production. OpenAI/Pi modes send text to OpenAI."
        )
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 140)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel("Dictation text")
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView

        backend.addItems(withTitles: DebugTranscriptCorrector.Backend.allCases.map(\.title))
        backend.target = self
        backend.action = #selector(changeBackend)
        backend.setAccessibilityLabel("Correction backend")
        source.addItems(withTitles: DebugDictationInputService.Source.allCases.map(\.title))
        source.target = self
        source.action = #selector(changeSource)
        source.setAccessibilityLabel("Speech recognition source")
        configure(prepareButton, action: #selector(prepareModel))
        partialField.placeholderString = "Provisional words"
        partialField.setAccessibilityLabel("Injected provisional text")
        let inject = NSButton(title: "Inject snapshot", target: self, action: #selector(injectSnapshot))
        fakeBehavior.addItems(withTitles: FakeOpenAI.Behavior.allCases.map(\.rawValue))
        fakeBehavior.target = self; fakeBehavior.action = #selector(changeFakeBehavior)
        fakeBehavior.setAccessibilityLabel("Fake HTTP response")
        let release = NSButton(title: "Release HTTP replies", target: self, action: #selector(releaseRequests))
        fault.addItems(withTitles: ["No input fault", "Hold preparation", "Fail preparation", "Fail stream", "Fail Stop", "Fail Cancel"])
        fault.target = self; fault.action = #selector(changeInputFault)
        fault.setAccessibilityLabel("Input fault")
        let releaseStart = NSButton(title: "Release preparation", target: self, action: #selector(releasePreparation))
        let inspect = NSButton(title: "Inspect payload", target: self, action: #selector(inspectPayload))
        let target = NSButton(title: "Show paste target", target: self, action: #selector(showPasteTarget))
        let state = NSButton(title: "Inspect state", target: self, action: #selector(inspectState))
        historyPicker.setAccessibilityLabel("Saved recording")
        let transcribe = NSButton(title: "Transcribe / Retry", target: self, action: #selector(transcribeHistory))
        let cancelHistory = NSButton(title: "Cancel upload", target: self, action: #selector(cancelHistory))
        let copyHistory = NSButton(title: "Copy saved transcript", target: self, action: #selector(copyHistory))
        let settings = NSButton(title: "Sentence cleanup…", target: self, action: #selector(showSettings))
        let speech = NSButton(title: "Speech recognition…", target: self, action: #selector(showSpeechSettings))
        for button in [inject, release, releaseStart, inspect, target, state, transcribe, cancelHistory, copyHistory, settings, speech] { button.bezelStyle = .rounded }
        harnessStatus.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        harnessStatus.setAccessibilityLabel("Harness connection")
        let replayButton = NSButton(title: "Replay audio…", target: self, action: #selector(replayAudio))
        replayButton.bezelStyle = .rounded
        let keyButton = NSButton(title: "Set API key…", target: self, action: #selector(setAPIKey))
        keyButton.bezelStyle = .rounded
        let clearButton = NSButton(title: "Clear log", target: self, action: #selector(clearLog))
        clearButton.bezelStyle = .rounded
        requestStatus.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        requestStatus.setAccessibilityLabel("Request activity")
        requestLog.isEditable = false
        requestLog.isRichText = false
        requestLog.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        requestLog.textContainerInset = NSSize(width: 8, height: 8)
        requestLog.isVerticallyResizable = true
        requestLog.isHorizontallyResizable = false
        requestLog.autoresizingMask = [.width]
        requestLog.textContainer?.widthTracksTextView = true
        requestLog.setAccessibilityLabel("Request diagnostics")
        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.documentView = requestLog

        configure(startButton, action: #selector(startDictation))
        configure(stopButton, action: #selector(stopDictation))
        configure(cancelButton, action: #selector(cancelDictation))
        configure(streamButton, action: #selector(streamText))
        let sampleButton = NSButton(title: "Load sample", target: self, action: #selector(loadSample))
        sampleButton.bezelStyle = .rounded
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityLabel("Dictation status")

        let controls = NSStackView(views: [
            title,
            description,
            row([source, prepareButton]),
            row([backend, keyButton]),
            row([fakeBehavior, release, inspect]),
            row([fault, releaseStart]),
            scrollView,
            row([partialField, inject]),
            row([startButton, stopButton, cancelButton]),
            row([streamButton, sampleButton, replayButton]),
            status,
            row([target, state]),
            row([historyPicker, speech, settings]),
            row([transcribe, cancelHistory, copyHistory]),
            harnessStatus,
            row([requestStatus, clearButton]),
            logScroll
        ])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            controls.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 20),
            controls.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
        for view in controls.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }

        let onStateChange = controller.onStateChange
        controller.onStateChange = { [weak self] in onStateChange?(); self?.updateControls() }
        corrector.onDiagnosticsChange = { [weak self] in self?.updateDiagnostics() }
        input.local.onDiagnostic = { [weak self] message in
            self?.recognitionLog += message + "\n"
            self?.updateDiagnostics()
        }
        input.audioFile.onDiagnostic = input.local.onDiagnostic
        input.audioFile.onFinished = { [weak controller] in
            Task { await controller?.stop() }
        }
        updateDiagnostics()
        updateControls()
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func renderDebugView(to url: URL) throws {
        try DebugViewRendering.writePNG(of: window!.contentView!, background: window!.backgroundColor, to: url)
    }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestStatus.stringValue = self?.corrector.activity ?? "" }
        }
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate()
        statusTimer = nil
        Task { await controller.cancel() }
    }

    func textDidChange(_ notification: Notification) {
        if input.source == .typed { input.typed.updateText(textView.string) }
    }

    private func configure(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
    }

    private func row(_ buttons: [NSView]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.spacing = 8
        row.distribution = .fillEqually
        return row
    }

    private func updateControls() {
        source.selectItem(at: input.source.rawValue)
        backend.selectItem(at: corrector.backend.rawValue)
        let faults = input.injected
        fault.selectItem(at: faults.holdPreparation ? 1 : faults.failStart ? 2 : faults.failStop ? 4 : faults.failCancel ? 5 : 0)
        if let harness {
            harnessStatus.stringValue = "Isolated data: \(harness.store.appDirectory.path)\nControl file: \(DebugEnvironment.controlFile.path)"
            do {
                let recordings = try harness.store.load()
                let selection = historyPicker.indexOfSelectedItem
                let selected = historyIDs.indices.contains(selection) ? historyIDs[selection] : nil
                historyIDs = recordings.map(\.id)
                historyPicker.removeAllItems()
                historyPicker.addItems(withTitles: recordings.map { "\($0.id.uuidString.prefix(8)) · \($0.transcriptionError == nil ? "saved" : "error")" })
                if let selected, let index = historyIDs.firstIndex(of: selected) { historyPicker.selectItem(at: index) }
            } catch { harnessStatus.stringValue = "Storage error: \(error.localizedDescription)" }
            Task { [weak self] in
                let behavior = await harness.fake.currentBehavior()
                self?.fakeBehavior.selectItem(at: FakeOpenAI.Behavior.allCases.firstIndex(of: behavior)!)
            }
        }
        backend.isEnabled = !controller.isActive
        source.isEnabled = !controller.isActive
        prepareButton.isEnabled = !controller.isActive && !preparingModel
        textView.isEditable = input.source == .typed || input.source == .injected
        streamButton.isEnabled = input.source == .typed
        startButton.isEnabled = !controller.isActive && (input.source != .audioFile || input.audioFile.audioURL != nil)
        stopButton.isEnabled = controller.isActive
        cancelButton.isEnabled = controller.isActive || !controller.transcript.text.isEmpty
        let count = controller.transcript.text.split(whereSeparator: \.isWhitespace).count
        let document = controller.correctionState
        let pending = document.pendingText.split(whereSeparator: \.isWhitespace).count
        let corrected = document.correctedText.split(whereSeparator: \.isWhitespace).count
        status.stringValue = "\(controller.isActive ? "Dictating" : "Ready") · \(count) words · \(pending) pending words · \(corrected) corrected words"
    }

    private func updateDiagnostics() {
        requestLog.string = recognitionLog + corrector.diagnostics
        requestLog.scrollToEndOfDocument(nil)
        requestStatus.stringValue = corrector.activity
    }

    @objc private func changeBackend() {
        corrector.backend = DebugTranscriptCorrector.Backend(rawValue: backend.indexOfSelectedItem)!
    }

    private var recognitionLog = "Nemotron 600M · 560 ms chunks · local Core ML\n"
    private var preparingModel = false

    @objc private func changeSource() {
        input.source = DebugDictationInputService.Source(rawValue: source.indexOfSelectedItem)!
        updateControls()
    }

    @objc private func injectSnapshot() {
        do { try input.injected.inject(.init(committedText: textView.string, partialText: partialField.stringValue)) }
        catch { corrector.log(error.localizedDescription) }
    }

    @objc private func changeFakeBehavior() {
        let behavior = FakeOpenAI.Behavior.allCases[fakeBehavior.indexOfSelectedItem]
        Task { await harness?.fake.configure(behavior: behavior) }
    }

    @objc private func releaseRequests() { Task { await harness?.fake.release() } }
    @objc private func releasePreparation() { Task { await input.injected.releasePreparation() } }

    @objc private func changeInputFault() {
        let selected = fault.indexOfSelectedItem
        input.injected.holdPreparation = selected == 1
        input.injected.failStart = selected == 2
        input.injected.failStop = selected == 4
        input.injected.failCancel = selected == 5
        if selected == 3 {
            do { try input.injected.injectFailure() } catch { corrector.log(error.localizedDescription) }
        }
    }

    @objc private func inspectPayload() {
        Task {
            if let receipt = await harness?.fake.receipts.last {
                corrector.log(receipt.payload ?? "Audio upload: \(receipt.audioBytes ?? 0) bytes; SHA256 \(receipt.audioSHA256 ?? "")")
            } else { corrector.log("No HTTP requests yet") }
        }
    }

    @objc private func showPasteTarget() { harness?.pasteTarget.show() }

    private func historyAction(_ action: DebugHarness.Command.Action) {
        let index = historyPicker.indexOfSelectedItem
        guard let harness, historyIDs.indices.contains(index) else { corrector.log("Save a recording first"); return }
        let data = try! JSONEncoder().encode(["action": action.rawValue, "recordingID": historyIDs[index].uuidString])
        Task {
            do { try await harness.execute(JSONDecoder().decode(DebugHarness.Command.self, from: data)) }
            catch { corrector.log(error.localizedDescription) }
        }
    }
    @objc private func transcribeHistory() { historyAction(.retryTranscription) }
    @objc private func cancelHistory() { historyAction(.cancelTranscription) }
    @objc private func copyHistory() { historyAction(.copyRecording) }
    @objc private func showSpeechSettings() {
        do { _ = try harness?.uiWindow?("speech", true) } catch { corrector.log(error.localizedDescription) }
    }
    @objc private func showSettings() {
        do { _ = try harness?.uiWindow?("settings", true) } catch { corrector.log(error.localizedDescription) }
    }

    @objc private func inspectState() {
        Task {
            guard let harness else { return }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            corrector.log(String(decoding: try! encoder.encode(await harness.snapshot()), as: UTF8.self))
        }
    }

    @objc private func prepareModel() {
        preparingModel = true
        prepareButton.title = "Downloading/loading…"
        updateControls()
        Task {
            let start = ContinuousClock.now
            do {
                try await input.local.prepareLocalModel()
                recognitionLog += "Model ready in \(start.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds])))\n"
                prepareButton.title = "Model ready"
            } catch {
                recognitionLog += "Model failed: \(error.localizedDescription)\n"
                prepareButton.title = "Retry model preparation"
            }
            preparingModel = false
            updateDiagnostics()
            updateControls()
        }
    }

    @objc private func replayAudio() {
        guard !controller.isActive else { return }
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.message = "Replay speech through the configured recognition engine in real time. Audio stays on this Mac."
        picker.begin { [weak self] response in
            guard response == .OK, let self, let url = picker.url else { return }
            self.input.audioFile.audioURL = url
            self.input.source = .audioFile
            self.source.selectItem(at: DebugDictationInputService.Source.audioFile.rawValue)
            self.recognitionLog += "Replaying \(url.lastPathComponent) in 80 ms packets\n"
            self.updateControls()
            self.startDictation()
        }
    }

    @objc private func setAPIKey() { onSetAPIKey() }
    @objc private func clearLog() { recognitionLog = ""; corrector.clearDiagnostics() }

    @objc private func startDictation() {
        Task {
            await controller.start()
            if controller.isActive && input.source == .typed { input.typed.updateText(textView.string) }
        }
    }

    @objc private func stopDictation() {
        Task { await controller.stop() }
    }

    @objc private func cancelDictation() {
        Task { await controller.cancel() }
    }

    @objc private func streamText() {
        let text = textView.string
        Task {
            if !controller.isActive { await controller.start() }
            if controller.isActive { input.typed.replay(text) }
        }
    }

    @objc private func loadSample() {
        textView.string = """
        The first version should stay focused on making everyday dictation feel effortless.
        Keep the panel near the bottom so my work remains visible.
        As I speak, new words should appear naturally at the bottom.
        Complete sentences can be recognized without interrupting the next thought.
        Older text should move upward and disappear beyond the top edge.
        I can keep talking while the application preserves the entire transcript.
        The latest words should remain visible even after earlier sentences scroll away.
        """
        if input.source == .typed { input.typed.updateText(textView.string) }
    }
}
#endif
