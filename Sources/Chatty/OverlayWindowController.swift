import AppKit

@MainActor
final class OverlayWindowController: NSWindowController {
    private let content = DictationOverlayView()
    private var recordingStartedAt: Date?
    private var durationTimer: Timer?

    var transcriptWidth: CGFloat { window!.frame.width - 48 }

    var onCancel: (() -> Void)? {
        get { content.onCancel }
        set { content.onCancel = newValue }
    }

    var onRetry: (() -> Void)? {
        get { content.onRetry }
        set { content.onRetry = newValue }
    }

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 128),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.contentView = content
        panel.setAccessibilityLabel("Live dictation")
        panel.setAccessibilitySubrole(.floatingWindow)
        super.init(window: panel)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showPreparing() {
        stopDurationTimer()
        content.setCorrections(TranscriptCorrections())
        content.setStatus("Preparing dictation…", color: .systemBlue, canCancel: true)
        showCentered()
    }

    func showRecording() {
        recordingStartedAt = Date()
        content.duration.stringValue = "0:00"
        content.setStatus("Listening", color: .systemRed, canCancel: true)
        content.waveform.setRecording(true)
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartedAt else { return }
                let seconds = Int(Date().timeIntervalSince(start))
                self.content.duration.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
            }
        }
        showCentered()
    }

    func updateCorrections(_ document: TranscriptCorrections) {
        content.setCorrections(document)
        if let window, window.isVisible, let screen = window.screen ?? NSScreen.main {
            layoutOverlay(on: screen)
        }
    }

    func updateLevel(_ level: Float) {
        content.waveform.setLevel(level)
    }

    func updateFileSize(_ bytes: Int64) {
        content.fileSize.stringValue = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func showProcessing(canCancel: Bool = false, canRetry: Bool = false, message: String = "Finishing transcription…") {
        stopDurationTimer()
        content.setStatus(message, color: .systemBlue, canCancel: canCancel, canRetry: canRetry)
        showCentered()
    }

    func showSuccess(message: String = "Copied transcript to clipboard") {
        stopDurationTimer()
        content.setStatus(message, color: .systemGreen, canCancel: true)
        showCentered()
    }

    func showError(_ message: String, canRetry: Bool = false) {
        stopDurationTimer()
        content.setStatus("Error: \(message)", color: .systemRed, canCancel: true, canRetry: canRetry)
        showCentered()
    }

    override func close() {
        stopDurationTimer()
        content.setCorrections(TranscriptCorrections())
        super.close()
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartedAt = nil
        content.waveform.setRecording(false)
    }

    private func showCentered() {
        guard let window, let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        layoutOverlay(on: screen)
        window.orderFrontRegardless()
    }

    private func layoutOverlay(on screen: NSScreen) {
        guard let window else { return }
        let frame = screen.visibleFrame
        let width = min(720, frame.width - 32)
        let height = content.preferredHeight(for: width)
        let target = NSRect(x: frame.midX - width / 2, y: frame.minY + 56, width: width, height: height)
        if window.frame != target {
            window.setFrame(target, display: true)
        }
        content.layoutSubtreeIfNeeded()
        content.scrollToNewestText()
    }

    @objc private func screenParametersChanged() {
        guard let window, window.isVisible, let screen = window.screen ?? NSScreen.main else { return }
        layoutOverlay(on: screen)
    }
}

@MainActor
private final class DictationOverlayView: NSVisualEffectView {
    let waveform = RecordingWaveformView()
    let duration = NSTextField(labelWithString: "")
    let fileSize = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "Listening")
    private let transcript = NSTextView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "New words appear below · Esc to copy and close")
    private let cancel = NSButton(title: "×", target: nil, action: nil)
    private let retry = NSButton(title: "↻", target: nil, action: nil)
    private let transcriptFont = TranscriptLayout.font
    private var transcriptLineHeight: CGFloat {
        ceil(transcript.layoutManager!.defaultLineHeight(for: transcriptFont)) + 5
    }
    var onCancel: (() -> Void)?
    var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer!.cornerRadius = 18
        layer!.masksToBounds = true
        layer!.borderWidth = 1
        layer!.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer!.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        let title = NSTextField(labelWithString: "Chatty")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        duration.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail
        fileSize.font = .systemFont(ofSize: 11)
        fileSize.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        cancel.target = self
        cancel.action = #selector(cancelClicked)
        cancel.toolTip = "Cancel or dismiss dictation"
        cancel.setAccessibilityLabel("Cancel dictation")
        retry.target = self
        retry.action = #selector(retryClicked)
        retry.toolTip = "Retry transcription"
        retry.setAccessibilityLabel("Retry transcription")
        for button in [cancel, retry] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 20)
            button.contentTintColor = .white
        }
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.isRichText = true
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.minSize = .zero
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.textContainerInset = NSSize(width: 0, height: 6)
        transcript.textContainer!.widthTracksTextView = true
        transcript.textContainer!.heightTracksTextView = false
        transcript.textContainer!.lineFragmentPadding = 0
        transcript.setAccessibilityLabel("Live transcript")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = transcript
        for view in [waveform, title, status, duration, cancel, retry, scroll, hint, fileSize] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            waveform.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            waveform.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            waveform.widthAnchor.constraint(equalToConstant: 90),
            waveform.heightAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: waveform.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: waveform.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: waveform.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: duration.leadingAnchor, constant: -12),
            cancel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            cancel.centerYAnchor.constraint(equalTo: waveform.centerYAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 24),
            retry.trailingAnchor.constraint(equalTo: cancel.leadingAnchor, constant: -6),
            retry.centerYAnchor.constraint(equalTo: cancel.centerYAnchor),
            retry.widthAnchor.constraint(equalToConstant: 24),
            duration.trailingAnchor.constraint(equalTo: retry.leadingAnchor, constant: -12),
            duration.centerYAnchor.constraint(equalTo: waveform.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 54),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -38),
            hint.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: fileSize.leadingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            fileSize.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            fileSize.centerYAnchor.constraint(equalTo: hint.centerYAnchor)
        ])
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setStatus(_ text: String, color: NSColor, canCancel: Bool, canRetry: Bool = false) {
        status.stringValue = text
        status.toolTip = text
        status.textColor = color
        cancel.isHidden = !canCancel
        retry.isHidden = !canRetry
    }

    func setCorrections(_ document: TranscriptCorrections) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = transcriptLineHeight
        paragraph.maximumLineHeight = transcriptLineHeight
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: transcriptFont,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let text = NSMutableAttributedString()
        for (section, color) in [(document.correctedText, NSColor.systemGreen), (document.pendingText, NSColor.systemYellow)] where !section.isEmpty {
            if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: attrs)) }
            var sectionAttrs = attrs
            sectionAttrs[.backgroundColor] = color.withAlphaComponent(0.25)
            text.append(NSAttributedString(string: section, attributes: sectionAttrs))
        }
        if !document.tail.isEmpty {
            if text.length > 0 { text.append(NSAttributedString(string: " ", attributes: attrs)) }
            text.append(NSAttributedString(string: document.tail, attributes: attrs))
        }
        transcript.textStorage!.setAttributedString(text)
        if text.length == 0 {
            duration.stringValue = ""
            fileSize.stringValue = ""
        }
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let textWidth = width - 48
        let container = transcript.textContainer!
        let manager = transcript.layoutManager!
        transcript.setFrameSize(NSSize(width: textWidth, height: transcript.frame.height))
        container.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)

        // Measure wrapped lines, including an empty final line after a newline.
        let laidOutHeight = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        let textHeight = max(transcriptLineHeight, ceil(laidOutHeight))
        let insets = transcript.textContainerInset.height * 2
        transcript.setFrameSize(NSSize(width: textWidth, height: textHeight + insets))
        let viewportHeight = min(textHeight, transcriptLineHeight * 5) + insets
        return 54 + viewportHeight + 38
    }

    func scrollToNewestText() {
        transcript.layoutManager!.ensureLayout(for: transcript.textContainer!)
        transcript.scrollRangeToVisible(NSRange(location: transcript.textStorage!.length, length: 0))
        // A correction can shorten the document as well as append to it.
        let bottom = max(0, transcript.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func cancelClicked() { onCancel?() }
    @objc private func retryClicked() { onRetry?() }
}
