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
    private var recordingHotkey: GlobalHotkey!
    private let configStore = ConfigStore()
    private let shortcutCapture = ShortcutCaptureController()
    private var config = AppConfig()
    private let overlay = OverlayWindowController()
    private let errorWindow = ErrorWindowController()
    private let transcriber = OpenAITranscriber()
    private let store = try! RecordingStore()
    private var pendingRecordingID: UUID?
    private var targetPasteApplication: NSRunningApplication?
    private var lastErrorMessage: String?
    private var transcribingIDs = Set<UUID>()
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptionRuns: [UUID: UUID] = [:]
    private var activeOverlayRecording: Recording?
    private var activeOverlayPasteAfterCopy = false

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
        overlay.onCancel = { [weak self] in self?.cancelOverlayAction() }
        overlay.onRetry = { [weak self] in self?.retryOverlayTranscription() }
        shortcut = DoubleShiftShortcut { [weak self] in self?.toggleRecording() }
        escapeShortcut = EscapeShortcut { [weak self] in self?.handleEscape() }
        recordingHotkey = GlobalHotkey(id: 2) { [weak self] in self?.toggleRecording() }
        config = configStore.load()
        applyBindings()
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
        let toggleLabel = config.recordingShortcut?.label ?? "Double Left Shift"
        let toggleStatus = NSMenuItem(title: "\(toggleLabel) toggles recording", action: nil, keyEquivalent: "")
        toggleStatus.isEnabled = false
        menu.addItem(toggleStatus)
        menu.addItem(NSMenuItem(title: "Escape cancels active recording", action: nil, keyEquivalent: ""))

        menu.addItem(NSMenuItem(title: "Set Recording Shortcut…", action: #selector(setRecordingShortcut), keyEquivalent: ""))
        if config.recordingShortcut != nil {
            menu.addItem(NSMenuItem(title: "Reset to Double Left Shift", action: #selector(clearRecordingShortcut), keyEquivalent: ""))
        }
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

    @objc private func setRecordingShortcut() {
        shortcutCapture.begin(current: config.recordingShortcut) { [weak self] binding in
            self?.applyRecordingShortcut(binding)
        }
    }

    @objc private func clearRecordingShortcut() {
        applyRecordingShortcut(nil)
    }

    private func applyRecordingShortcut(_ binding: KeyBinding?) {
        do {
            config = try configStore.setRecordingShortcut(binding)
            applyBindings()
            refreshMenu()
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// The recording toggle is a single binding: a custom chord replaces the
    /// default double-left-Shift, which is only active when no chord is set.
    private func applyBindings() {
        if let binding = config.recordingShortcut {
            shortcut.stop()
            recordingHotkey.update(binding: binding)
        } else {
            recordingHotkey.update(binding: nil)
            shortcut.start()
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
        copyTextToClipboard(transcript)
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
                    transcribe(recording, pasteAfterCopy: true)
                } catch {
                    showError(error.localizedDescription)
                }
            } else {
                do {
                    let destination = try store.makeRecordingURL()
                    pendingRecordingID = destination.id
                    targetPasteApplication = NSWorkspace.shared.frontmostApplication
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
        cancelOverlayAction()
    }

    private func cancelOverlayAction() {
        if recorder.isRecording {
            cancelRecording()
            return
        }

        guard let activeOverlayRecording else {
            dismissErrorUI()
            return
        }
        cancelTranscription(id: activeOverlayRecording.id, closeOverlay: true)
    }

    private func retryOverlayTranscription() {
        guard let recording = activeOverlayRecording else { return }
        let pasteAfterCopy = activeOverlayPasteAfterCopy
        cancelTranscription(id: recording.id, closeOverlay: false)
        transcribe(recording, pasteAfterCopy: pasteAfterCopy)
    }

    private func cancelRecording() {
        do {
            try recorder.cancel()
            escapeShortcut.stop()
            pendingRecordingID = nil
            targetPasteApplication = nil
            activeOverlayRecording = nil
            activeOverlayPasteAfterCopy = false
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

    private func showTranscriptionError(_ message: String, recording: Recording, pasteAfterCopy: Bool) {
        lastErrorMessage = message
        activeOverlayRecording = recording
        activeOverlayPasteAfterCopy = pasteAfterCopy
        refreshMenu()
        overlay.showError(message, canRetry: true)
        errorWindow.show(message: message)
    }

    private func copyTextToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyTranscriptAndPaste(_ transcript: String) {
        copyTextToClipboard(transcript)

        let targetApplication = targetPasteApplication
        targetPasteApplication = nil
        targetApplication?.activate(options: [])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.pasteClipboardContents()
        }
    }

    private func pasteClipboardContents() {
        let commandKey: CGKeyCode = 0x37
        let vKey: CGKeyCode = 0x09

        guard let source = CGEventSource(stateID: .hidSystemState),
              let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKey, keyDown: false)
        else {
            showError("Could not create paste keyboard event.")
            return
        }

        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        commandDown.post(tap: .cghidEventTap)
        vDown.post(tap: .cghidEventTap)
        vUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
    }

    private func transcribe(_ recording: Recording, pasteAfterCopy: Bool = false) {
        guard transcriptionTasks[recording.id] == nil else { return }
        let runID = UUID()
        transcribingIDs.insert(recording.id)
        transcriptionRuns[recording.id] = runID
        escapeShortcut.start()
        activeOverlayRecording = recording
        activeOverlayPasteAfterCopy = pasteAfterCopy
        refreshMenu()
        overlay.showProcessing(canCancel: true, canRetry: true)

        let task = Task { @MainActor in
            do {
                let text = try await transcriber.transcribe(file: recording.audioURL)
                guard !Task.isCancelled else {
                    finishTranscription(id: recording.id, runID: runID)
                    return
                }
                try store.updateTranscript(for: recording.id, transcript: text)
                if pasteAfterCopy {
                    copyTranscriptAndPaste(text)
                } else {
                    copyTextToClipboard(text)
                }
                finishTranscription(id: recording.id, runID: runID)
                overlay.showSuccess()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.overlay.close() }
            } catch is CancellationError {
                finishTranscription(id: recording.id, runID: runID)
            } catch {
                guard !Task.isCancelled else {
                    finishTranscription(id: recording.id, runID: runID)
                    return
                }
                finishTranscription(id: recording.id, runID: runID)
                do {
                    try store.updateError(for: recording.id, message: error.localizedDescription)
                } catch {
                    showError(error.localizedDescription)
                }
                refreshMenu()
                showTranscriptionError(error.localizedDescription, recording: recording, pasteAfterCopy: pasteAfterCopy)
            }
        }
        transcriptionTasks[recording.id] = task
    }

    private func cancelTranscription(id: UUID, closeOverlay: Bool) {
        let runID = transcriptionRuns[id]
        transcriptionTasks[id]?.cancel()
        finishTranscription(id: id, runID: runID)
        if closeOverlay {
            activeOverlayRecording = nil
            activeOverlayPasteAfterCopy = false
            overlay.close()
        }
    }

    private func finishTranscription(id: UUID, runID: UUID?) {
        guard transcriptionRuns[id] == runID else { return }
        transcriptionTasks[id] = nil
        transcriptionRuns[id] = nil
        transcribingIDs.remove(id)
        if activeOverlayRecording?.id == id {
            activeOverlayRecording = nil
            activeOverlayPasteAfterCopy = false
        }
        if transcriptionTasks.isEmpty && !recorder.isRecording {
            escapeShortcut.stop()
        }
        refreshMenu()
    }
}

let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
