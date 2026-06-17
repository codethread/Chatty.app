import AppKit

@MainActor
final class OverlayWindowController: NSWindowController {
    private let content = OverlayView()
    private var recordingStartedAt: Date?
    private var durationTimer: Timer?

    init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.contentView = content
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showRecording() {
        recordingStartedAt = Date()
        content.state = .recording(level: 0, duration: 0, fileSize: 0)
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickRecordingDuration() }
        }
        showCentered()
    }

    func updateLevel(_ level: Float) {
        if case .recording(_, let duration, let fileSize) = content.state {
            content.state = .recording(level: level, duration: duration, fileSize: fileSize)
        }
    }

    func updateFileSize(_ bytes: Int64) {
        if case .recording(let level, let duration, _) = content.state {
            content.state = .recording(level: level, duration: duration, fileSize: bytes)
        }
    }

    func showProcessing() {
        stopDurationTimer()
        content.state = .processing
        showCentered()
    }

    func showSuccess() {
        stopDurationTimer()
        content.state = .success
        showCentered()
    }

    func showError(_ message: String) {
        stopDurationTimer()
        content.state = .error(message)
        showCentered()
    }

    override func close() {
        stopDurationTimer()
        super.close()
    }

    private func tickRecordingDuration() {
        guard let recordingStartedAt else { return }
        let duration = Int(Date().timeIntervalSince(recordingStartedAt))
        if case .recording(let level, _, let fileSize) = content.state {
            content.state = .recording(level: level, duration: duration, fileSize: fileSize)
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStartedAt = nil
    }

    private func showCentered() {
        guard let window else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2, y: frame.minY + 56))
        }
        window.orderFrontRegardless()
    }
}

@MainActor
private final class OverlayView: NSView {
    enum State { case recording(level: Float, duration: Int, fileSize: Int64), processing, success, error(String) }
    private static let maxUploadBytes: Double = 25 * 1024 * 1024
    var state: State = .recording(level: 0, duration: 0, fileSize: 0) { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let rect = bounds.insetBy(dx: 8, dy: 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()

        let (title, color): (String, NSColor) = switch state {
        case .recording(let level, let duration, let fileSize):
            (recordingTitle(level: level, duration: duration, fileSize: fileSize), recordingColor(level: level, fileSize: fileSize))
        case .processing: ("Transcribing…", .systemBlue)
        case .success: ("Copied transcript to clipboard", .systemGreen)
        case .error(let msg): ("Error: \(msg)", .systemRed)
        }

        color.setFill()
        let dotSize: CGFloat = switch state {
        case .recording(let level, _, _): level > 0 ? 22 : 16
        case .processing: 18
        default: 16
        }
        NSBezierPath(ovalIn: NSRect(x: 28, y: bounds.midY - dotSize / 2, width: dotSize, height: dotSize)).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        title.draw(in: NSRect(x: 64, y: bounds.midY - 10, width: bounds.width - 88, height: 24), withAttributes: attrs)
    }

    private func recordingTitle(level: Float, duration: Int, fileSize: Int64) -> String {
        let size = formatBytes(fileSize)
        let percent = Double(fileSize) / Self.maxUploadBytes
        let warning = if percent >= 0.9 {
            " · upload limit close"
        } else if percent >= 0.7 {
            " · size warning"
        } else {
            ""
        }
        let sound = level > 0 ? " · sound detected" : ""
        return "Recording · \(formatDuration(duration)) · \(size)\(warning)\(sound)"
    }

    private func recordingColor(level: Float, fileSize: Int64) -> NSColor {
        let percent = Double(fileSize) / Self.maxUploadBytes
        if percent >= 0.9 { return .systemRed }
        if percent >= 0.7 { return .systemYellow }
        return level > 0 ? .systemOrange : .systemRed
    }

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let seconds = seconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
