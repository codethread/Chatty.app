import AppKit
import AVFoundation
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var recordingsMenu = NSMenu(title: "Recordings")
    private var recorder = AudioRecorder()
    private var shortcut: DoubleShiftShortcut!
    private var escapeShortcut: EscapeShortcut!
    private let overlay = OverlayWindowController()
    private let errorWindow = ErrorWindowController()
    private let transcriber = OpenAITranscriber()
    private let store = try! RecordingStore()
    private var pendingRecordingID: UUID?
    private var lastErrorMessage: String?
    private var transcribingIDs = Set<UUID>()

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        pruneExpiredRecordings()
        setupMenu()
        recorder.onLevelChange = { [weak self] level in self?.overlay.updateLevel(level) }
        recorder.onFileSizeChange = { [weak self] bytes in self?.overlay.updateFileSize(bytes) }
        shortcut = DoubleShiftShortcut { [weak self] in self?.toggleRecording() }
        shortcut.start()
        escapeShortcut = EscapeShortcut { [weak self] in self?.handleEscape() }
        runInitialSetup()
    }

    private func pruneExpiredRecordings() {
        do {
            _ = try store.pruneRecordingsOlderThan(days: Settings.recordingRetentionDays)
        } catch {
            overlay.showError(error.localizedDescription)
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        refreshMenu()
    }

    private func refreshMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Chatty", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Set OpenAI API Key…", action: #selector(setAPIKey), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Double Left Shift toggles recording", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Escape cancels active recording", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        if lastErrorMessage != nil {
            menu.addItem(NSMenuItem(title: "Show Last Error…", action: #selector(showLastError), keyEquivalent: "e"))
        }

        let recordingsItem = NSMenuItem(title: "Recordings", action: nil, keyEquivalent: "")
        recordingsItem.submenu = buildRecordingsMenu()
        menu.addItem(recordingsItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func buildRecordingsMenu() -> NSMenu {
        let menu = NSMenu(title: "Recordings")
        do {
            let recordings = try store.load()
            guard !recordings.isEmpty else {
                let item = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
                return menu
            }

            for recording in recordings {
                let title = dateFormatter.string(from: recording.createdAt)
                let recordingItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)

                let openItem = NSMenuItem(title: "Open Recording", action: #selector(openRecording(_:)), keyEquivalent: "")
                openItem.representedObject = recording.id.uuidString
                submenu.addItem(openItem)

                if transcribingIDs.contains(recording.id) {
                    let item = NSMenuItem(title: "Transcribing…", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    submenu.addItem(item)
                } else if let transcript = recording.transcript, !transcript.isEmpty {
                    let item = NSMenuItem(title: "Transcript: \(preview(transcript))", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    submenu.addItem(item)

                    let copyItem = NSMenuItem(title: "Copy Transcript", action: #selector(copyTranscript(_:)), keyEquivalent: "")
                    copyItem.representedObject = recording.id.uuidString
                    submenu.addItem(copyItem)
                } else {
                    let item = NSMenuItem(title: "Transcribe Now", action: #selector(transcribeRecording(_:)), keyEquivalent: "")
                    item.representedObject = recording.id.uuidString
                    submenu.addItem(item)
                }

                if let error = recording.transcriptionError, !error.isEmpty {
                    let errorItem = NSMenuItem(title: "Show Error: \(preview(error))", action: #selector(showRecordingError(_:)), keyEquivalent: "")
                    errorItem.representedObject = recording.id.uuidString
                    submenu.addItem(errorItem)

                    let retryItem = NSMenuItem(title: "Try Again", action: #selector(transcribeRecording(_:)), keyEquivalent: "")
                    retryItem.representedObject = recording.id.uuidString
                    submenu.addItem(retryItem)

                    let clearItem = NSMenuItem(title: "Clear Error", action: #selector(clearRecordingError(_:)), keyEquivalent: "")
                    clearItem.representedObject = recording.id.uuidString
                    submenu.addItem(clearItem)
                }

                recordingItem.submenu = submenu
                menu.addItem(recordingItem)
            }
        } catch {
            let item = NSMenuItem(title: "Could not load recordings: \(preview(error.localizedDescription))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        return menu
    }

    private func preview(_ text: String, limit: Int = 120) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)) + "…"
    }

    private func runInitialSetup() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if KeychainStore.readAPIKey().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setAPIKey()
            }
        }
    }

    @objc private func setAPIKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Stored in Keychain for this app."
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
                showError(error.localizedDescription)
            }
        }
    }

    @objc private func showLastError() {
        guard let lastErrorMessage else { return }
        errorWindow.show(message: lastErrorMessage)
    }

    @objc private func openRecording(_ sender: NSMenuItem) {
        guard let recording = recording(from: sender) else { return }
        openInQuickTime(recording.audioURL)
    }

    private func openInQuickTime(_ url: URL) {
        guard let quickTimeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.QuickTimePlayerX") else {
            showError("QuickTime Player is not available.")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: quickTimeURL, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.showError(error.localizedDescription) }
        }
    }

    @objc private func transcribeRecording(_ sender: NSMenuItem) {
        guard let recording = recording(from: sender) else { return }
        transcribe(recording)
    }

    @objc private func copyTranscript(_ sender: NSMenuItem) {
        guard let recording = recording(from: sender), let transcript = recording.transcript, !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        overlay.showSuccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.overlay.close() }
    }

    @objc private func showRecordingError(_ sender: NSMenuItem) {
        guard let recording = recording(from: sender), let error = recording.transcriptionError else { return }
        errorWindow.show(message: error)
    }

    @objc private func clearRecordingError(_ sender: NSMenuItem) {
        guard let id = id(from: sender) else { return }
        do {
            try store.clearError(for: id)
            refreshMenu()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func recording(from sender: NSMenuItem) -> Recording? {
        guard let id = id(from: sender) else { return nil }
        do {
            return try store.load().first { $0.id == id }
        } catch {
            showError(error.localizedDescription)
            return nil
        }
    }

    private func id(from sender: NSMenuItem) -> UUID? {
        guard let string = sender.representedObject as? String, let id = UUID(uuidString: string) else {
            showError("Could not identify recording.")
            return nil
        }
        return id
    }

    private func toggleRecording() {
        Task { @MainActor in
            if recorder.isRecording {
                do {
                    overlay.showProcessing()
                    let file = try recorder.stop()
                    escapeShortcut.stop()
                    guard let pendingRecordingID else { throw AudioError.notRecording }
                    self.pendingRecordingID = nil
                    let recording = try store.addRecording(id: pendingRecordingID, audioURL: file)
                    refreshMenu()
                    transcribe(recording)
                } catch {
                    showError(error.localizedDescription)
                }
            } else {
                do {
                    let destination = try store.makeRecordingURL()
                    pendingRecordingID = destination.id
                    try await recorder.start(fileURL: destination.url)
                    escapeShortcut.start()
                    overlay.showRecording()
                } catch {
                    pendingRecordingID = nil
                    showError(error.localizedDescription)
                }
            }
        }
    }

    private func handleEscape() {
        guard recorder.isRecording else { return }
        cancelRecording()
    }

    private func cancelRecording() {
        do {
            try recorder.cancel()
            escapeShortcut.stop()
            pendingRecordingID = nil
            overlay.close()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func dismissErrorUI() {
        overlay.close()
        errorWindow.dismiss()
    }

    private func showError(_ message: String) {
        lastErrorMessage = message
        refreshMenu()
        overlay.showError(message)
        errorWindow.show(message: message)
    }

    private func transcribe(_ recording: Recording) {
        guard !transcribingIDs.contains(recording.id) else { return }
        transcribingIDs.insert(recording.id)
        refreshMenu()
        overlay.showProcessing()

        Task { @MainActor in
            do {
                let text = try await transcriber.transcribe(file: recording.audioURL)
                try store.updateTranscript(for: recording.id, transcript: text)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                transcribingIDs.remove(recording.id)
                refreshMenu()
                overlay.showSuccess()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.overlay.close() }
            } catch {
                transcribingIDs.remove(recording.id)
                do {
                    try store.updateError(for: recording.id, message: error.localizedDescription)
                } catch {
                    showError(error.localizedDescription)
                }
                refreshMenu()
                showError(error.localizedDescription)
            }
        }
    }
}

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
