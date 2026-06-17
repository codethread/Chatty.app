import AppKit
import AVFoundation
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recorder = AudioRecorder()
    private var shortcut: DoubleShiftShortcut!
    private let overlay = OverlayWindowController()
    private let transcriber = OpenAITranscriber()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        recorder.onLevelChange = { [weak self] level in self?.overlay.updateLevel(level) }
        shortcut = DoubleShiftShortcut { [weak self] in self?.toggleRecording() }
        shortcut.start()
        requestPermissions()
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Chatty", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Set OpenAI API Key…", action: #selector(setAPIKey), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Double Left Shift toggles recording", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @objc private func setAPIKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Stored in UserDefaults for this app."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = KeychainStore.readAPIKey()
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try KeychainStore.saveAPIKey(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                overlay.showError(error.localizedDescription)
            }
        }
    }

    private func toggleRecording() {
        Task { @MainActor in
            if recorder.isRecording {
                do {
                    overlay.showProcessing()
                    let file = try recorder.stop()
                    let text = try await transcriber.transcribe(file: file)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    overlay.showSuccess()
                    try? FileManager.default.removeItem(at: file)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.overlay.close() }
                } catch {
                    overlay.showError(error.localizedDescription)
                }
            } else {
                do {
                    try await recorder.start()
                    overlay.showRecording()
                } catch {
                    overlay.showError(error.localizedDescription)
                }
            }
        }
    }
}

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
