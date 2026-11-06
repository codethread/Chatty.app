import AppKit
import QuartzCore

@MainActor
final class RecordingWaveformView: NSView {
    private var recording = false
    private var inputLevel: CGFloat = 0
    private var displayedLevel: CGFloat = 0
    private var lastInputTime: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var phase: CGFloat = 0
    private var animationTimer: Timer?
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    override var intrinsicContentSize: NSSize { NSSize(width: 90, height: 24) }

    override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit {
        animationTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func setLevel(_ level: Float) {
        inputLevel = CGFloat(level)
        lastInputTime = CACurrentMediaTime()
    }

    func setRecording(_ active: Bool) {
        recording = active
        if !active {
            inputLevel = 0
            displayedLevel = 0
            phase = 0
            needsDisplay = true
        }
        updateAnimation()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        }
        stopAnimation()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowVisibilityChanged),
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose),
                name: NSWindow.willCloseNotification, object: window
            )
        }
        updateAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
    }

    override func draw(_ dirtyRect: NSRect) {
        let count = 17
        let barWidth: CGFloat = 3
        let step: CGFloat = 5
        let startX = bounds.midX - (CGFloat(count - 1) * step + barWidth) / 2
        let color = NSColor(calibratedRed: 0.52, green: 0.85, blue: 1, alpha: 1)

        for index in 0..<count {
            let position = CGFloat(index) / CGFloat(count - 1)
            let envelope = pow(sin(position * .pi), 0.75)
            let quietHeight = 3 + envelope * 1.5
            let ripple: CGFloat = reduceMotion ? 0.8 :
                0.55 + 0.3 * sin(phase - position * .pi * 3) + 0.15 * sin(phase * 1.7 + position * .pi * 5)
            let height = quietHeight + displayedLevel * (bounds.height - quietHeight - 2) * (0.25 + 0.75 * envelope) * ripple
            let rect = NSRect(x: startX + CGFloat(index) * step, y: bounds.midY - height / 2, width: barWidth, height: height)
            color.withAlphaComponent(0.48 + displayedLevel * 0.42).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    @objc private func accessibilityOptionsChanged() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        stopAnimation()
        updateAnimation()
        needsDisplay = true
    }

    @objc private func windowVisibilityChanged() { updateAnimation() }
    @objc private func windowWillClose() { stopAnimation() }

    private func updateAnimation() {
        guard recording, window?.isVisible == true, !isHiddenOrHasHiddenAncestor else {
            stopAnimation()
            return
        }
        guard animationTimer == nil else { return }
        lastFrameTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: reduceMotion ? 0.1 : 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceFrame()
            }
        }
        timer.tolerance = reduceMotion ? 0.02 : 0.005
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func advanceFrame() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastFrameTime
        lastFrameTime = now
        // A single debug input pulse settles even when no subsequent meter event arrives.
        let inputAge = now - lastInputTime
        let target = inputAge > 1.5 ? 0 : inputLevel * exp(-max(0, inputAge - 0.22) / 0.24)
        if reduceMotion {
            displayedLevel = target
        } else {
            let timeConstant = target > displayedLevel ? 0.07 : 0.24
            displayedLevel += (target - displayedLevel) * (1 - exp(-elapsed / timeConstant))
            phase += elapsed * 7
        }
        needsDisplay = true
    }
}
