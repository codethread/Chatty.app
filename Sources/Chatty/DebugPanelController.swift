#if CHATTY_DEBUG_PANEL
import AppKit

@MainActor
final class DebugPanelController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    private let input: DebugTextInputService
    private let controller: DictationController
    private let corrector: DebugTranscriptCorrector
    private let onSetAPIKey: () -> Void
    private let backend = NSPopUpButton()
    private let requestStatus = NSTextField(labelWithString: "Ready")
    private let requestLog = NSTextView()
    private var statusTimer: Timer?
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 180))
    private let status = NSTextField(labelWithString: "Ready — enter text, then start dictation.")
    private let startButton = NSButton(title: "Start dictation", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop dictation", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let streamButton = NSButton(title: "Stream text", target: nil, action: nil)

    init(input: DebugTextInputService, controller: DictationController, corrector: DebugTranscriptCorrector,
         onSetAPIKey: @escaping () -> Void) {
        self.input = input
        self.controller = controller
        self.corrector = corrector
        self.onSetAPIKey = onSetAPIKey
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Chatty Debug Panel"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.setAccessibilitySubrole(.floatingWindow)
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 640, height: 650)
        super.init(window: panel)
        panel.delegate = self

        let title = NSTextField(labelWithString: "Live dictation")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString:
            "Use typed text with the real OpenAI request, Pi, or the one-second uppercase fake. Stop or Escape copies the text and closes the overlay. No microphone is used. Live modes send your text to OpenAI."
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
            row([backend, keyButton]),
            scrollView,
            row([startButton, stopButton, cancelButton]),
            row([streamButton, sampleButton]),
            status,
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
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        for view in controls.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        }

        controller.onStateChange = { [weak self] in self?.updateControls() }
        corrector.onDiagnosticsChange = { [weak self] in self?.updateDiagnostics() }
        updateDiagnostics()
        updateControls()
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        input.updateText(textView.string)
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
        backend.isEnabled = !controller.isActive
        startButton.isEnabled = !controller.isActive
        stopButton.isEnabled = controller.isActive
        cancelButton.isEnabled = controller.isActive || !controller.transcript.text.isEmpty
        let count = controller.transcript.text.split(whereSeparator: \.isWhitespace).count
        let document = controller.correctionState
        let pending = document.pendingText.split(whereSeparator: \.isWhitespace).count
        let corrected = document.correctedText.split(whereSeparator: \.isWhitespace).count
        status.stringValue = "\(controller.isActive ? "Dictating" : "Ready") · \(count) words · \(pending) pending words · \(corrected) corrected words"
    }

    private func updateDiagnostics() {
        requestLog.string = corrector.diagnostics
        requestLog.scrollToEndOfDocument(nil)
        requestStatus.stringValue = corrector.activity
    }

    @objc private func changeBackend() {
        corrector.backend = DebugTranscriptCorrector.Backend(rawValue: backend.indexOfSelectedItem)!
    }

    @objc private func setAPIKey() { onSetAPIKey() }
    @objc private func clearLog() { corrector.clearDiagnostics() }

    @objc private func startDictation() {
        Task {
            await controller.start()
            if controller.isActive { input.updateText(textView.string) }
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
            if controller.isActive { input.replay(text) }
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
        input.updateText(textView.string)
    }
}
#endif
