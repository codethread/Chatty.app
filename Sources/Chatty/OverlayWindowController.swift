import AppKit

@MainActor
final class OverlayWindowController: NSWindowController {
    private let content = OverlayView()

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
        content.state = .recording(level: 0)
        showCentered()
    }

    func updateLevel(_ level: Float) {
        if case .recording = content.state {
            content.state = .recording(level: level)
        }
    }

    func showProcessing() {
        content.state = .processing
        showCentered()
    }

    func showSuccess() {
        content.state = .success
        showCentered()
    }

    func showError(_ message: String) {
        content.state = .error(message)
        showCentered()
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
    enum State { case recording(level: Float), processing, success, error(String) }
    var state: State = .recording(level: 0) { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let rect = bounds.insetBy(dx: 8, dy: 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22)
        NSColor.black.withAlphaComponent(0.78).setFill()
        path.fill()

        let (title, color): (String, NSColor) = switch state {
        case .recording(let level): (level > 0 ? "Recording · sound detected" : "Recording…", level > 0 ? .systemOrange : .systemRed)
        case .processing: ("Transcribing…", .systemBlue)
        case .success: ("Copied transcript to clipboard", .systemGreen)
        case .error(let msg): ("Error: \(msg)", .systemRed)
        }

        color.setFill()
        let dotSize: CGFloat = switch state {
        case .recording(let level): level > 0 ? 22 : 16
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
}
