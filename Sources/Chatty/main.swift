import AppKit
import AVFoundation
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var shortcut: DoubleShiftShortcut!
    private var escapeShortcut: EscapeShortcut!
    private var recordingHotkey: GlobalHotkey!
    #if CHATTY_DEBUG_PANEL
    private let configStore = ConfigStore(directory: DebugEnvironment.directory)
    private let store = try! RecordingStore(directory: DebugEnvironment.directory)
    private let fakeAPI = FakeOpenAI()
    private var harness: DebugHarness?
    private var debugGlobalShortcuts = false
    #else
    private let configStore = ConfigStore()
    private let store = try! RecordingStore()
    #endif
    private let shortcutCapture = ShortcutCaptureController()
    private var config = AppConfig()
    private let overlay = OverlayWindowController()
    private lazy var presentation = OverlayPresentation(overlay)
    private let openAICredentials = OpenAICredentials()
    #if CHATTY_DEBUG_PANEL
    private let localRecognizer = LocalSpeechRecognizer(modelRoot: DebugEnvironment.modelRoot)
    #else
    private let localRecognizer = LocalSpeechRecognizer()
    #endif
    #if CHATTY_DEBUG_PANEL
    private lazy var input = DebugDictationInputService(recognizer: localRecognizer)
    private lazy var debugCorrector = DebugTranscriptCorrector(credentials: openAICredentials)
    private lazy var corrections = CorrectionController(corrector: debugCorrector)
    private lazy var debugPanel = DebugPanelController(input: input, controller: dictation, corrector: debugCorrector,
                                                      onSetAPIKey: { [weak self] in self?.setAPIKey() })
    #else
    private lazy var input = MicrophoneDictationService(localRecognizer: localRecognizer)
    private lazy var corrections = CorrectionController(corrector: OpenAITranscriptCorrector(credentials: openAICredentials))
    #endif
    private lazy var dictation = DictationController(input: input, corrections: corrections, overlay: presentation.session(for: .dictation), recordings: store)
    private let errorWindow = ErrorWindowController()
    private lazy var correctionSettingsWindow = CorrectionSettingsWindowController { [unowned self] settings in
        config = try configStore.setCorrectionSettings(settings)
        corrections.settings = settings
        refreshMenu()
    }
    private lazy var speechSettingsWindow = SpeechSettingsWindowController(recognizer: localRecognizer) { [unowned self] engine in
        config = try configStore.setSpeechRecognition(engine)
        applySpeechEngine()
        refreshMenu()
    }
    private func applySpeechEngine() {
        #if CHATTY_DEBUG_PANEL
        input.setEngine(config.effectiveSpeechRecognition)
        #else
        input.backend = config.effectiveSpeechRecognition
        #endif
    }
    @objc private func editSpeechRecognition() {
        speechSettingsWindow.show(engine: config.effectiveSpeechRecognition)
    }

    private lazy var history = RecordingTranscriptionController(store: store, presentation: presentation) { [credentials = openAICredentials] file, prompt in
        try await OpenAITranscriber(credentials: credentials).transcribe(file: file, prompt: prompt)
    }
    private var targetPasteApplication: NSRunningApplication?
    private var lastErrorMessage: String?

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if CHATTY_DEBUG_PANEL
        Task {
            do {
                let url = try await fakeAPI.start()
                debugCorrector.connectFake(to: url)
                let transcriber = OpenAITranscriber(credentials: OpenAICredentials(apiKey: FakeOpenAI.apiKey),
                                                    endpoint: url.appendingPathComponent("v1/audio/transcriptions"))
                history.transcribe = { file, prompt in try await transcriber.transcribe(file: file, prompt: prompt) }
                configureApplication()
                let harness = DebugHarness(input: input, corrector: debugCorrector, controller: dictation,
                                           fake: fakeAPI, store: store, configStore: configStore,
                                           corrections: corrections, overlay: overlay, history: history, recognizer: localRecognizer)
                self.harness = harness
                harness.renderPanel = { [unowned self] url in try debugPanel.renderDebugView(to: url) }
                harness.uiWindow = { [unowned self] name, show in
                    switch name {
                    case "panel": if show { debugPanel.show() }; return debugPanel.window!
                    case "speech":
                        if show { speechSettingsWindow.show(engine: config.effectiveSpeechRecognition) }
                        return speechSettingsWindow.window!
                    case "settings":
                        if show { correctionSettingsWindow.show(settings: config.effectiveCorrectionSettings) }
                        return correctionSettingsWindow.window!
                    case "paste": if show { self.harness!.pasteTarget.show() }; return self.harness!.pasteTarget.window!
                    case "shortcut":
                        if show { setRecordingShortcut() }
                        guard let window = shortcutCapture.debugWindow else { throw DebugInputError.injected("Shortcut capture is closed") }
                        return window
                    default: throw DebugInputError.injected("UI view must be panel, settings, paste or shortcut")
                    }
                }
                harness.platformState = { [unowned self] in
                    ["recordingHotkey": String(recordingHotkey.isRegistered), "escapeHotkey": String(escapeShortcut.isRegistered),
                     "shortcut": config.recordingShortcut?.label ?? "Double Left Shift",
                     "accessibility": String(AXIsProcessTrusted()),
                     "microphone": String(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)]
                }
                harness.shortcutKey = { [unowned self] code, flags, chars in try shortcutCapture.injectKey(code: code, modifiers: flags, characters: chars) }
                harness.resetShortcut = { [unowned self] in applyRecordingShortcut(nil) }
                harness.onSettings = { [weak self] config in self?.config = config; self?.applySpeechEngine(); self?.refreshMenu() }
                harness.onReset = { [weak self] in self?.dismissErrorUI(); self?.refreshMenu() }
                harness.onGlobalShortcuts = { [weak self] enabled in
                    self?.debugGlobalShortcuts = enabled
                    self?.applyBindings()
                }
                try await harness.start()
                debugPanel.harness = harness
            } catch { showError(error.localizedDescription) }
        }
        #else
        configureApplication()
        #endif
    }

    private func configureApplication() {
        #if CHATTY_DEBUG_PANEL
        NSApp.setActivationPolicy(.regular)
        #else
        NSApp.setActivationPolicy(.accessory)
        #endif
        pruneExpiredRecordings()
        setupMenu()
        overlay.onCancel = { [weak self] in self?.cancelOverlayAction() }
        overlay.onRetry = { [weak self] in self?.retryOverlayTranscription() }
        shortcut = DoubleShiftShortcut { [weak self] in self?.toggleRecording() }
        escapeShortcut = EscapeShortcut { [weak self] in self?.handleEscape() }
        recordingHotkey = GlobalHotkey(id: 2) { [weak self] in self?.toggleRecording() }
        dictation.onActivityChange = { [weak self] _ in self?.updateEscapeBinding(); self?.refreshMenu() }
        history.onChange = { [weak self] in self?.updateEscapeBinding(); self?.refreshMenu() }
        history.onCopy = { [weak self] text in self?.copyTextToClipboard(text) }
        history.onPaste = { [weak self] in self?.pasteTranscript() }
        history.onError = { [weak self] message in self?.reportError(message) }
        dictation.onCopy = { [weak self] text in self?.copyTextToClipboard(text) }
        dictation.onComplete = { [weak self] text in
            #if CHATTY_DEBUG_PANEL
            self?.harness?.recordCompletion(text)
            #endif
            self?.pasteTranscript()
            self?.refreshMenu()
        }
        dictation.onError = { [weak self] message in self?.reportError(message) }
        do {
            config = try configStore.load()
        } catch {
            showError("Could not load Chatty settings: \(error.localizedDescription)")
            return
        }
        corrections.settings = config.effectiveCorrectionSettings
        applySpeechEngine()
        applyBindings()
        #if CHATTY_DEBUG_PANEL
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Show Debug Panel…", action: #selector(showDebugPanel), keyEquivalent: "0"))
        appMenu.addItem(NSMenuItem(title: "Speech Recognition…", action: #selector(editSpeechRecognition), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem(title: "Sentence Cleanup…", action: #selector(editSentenceCleanup), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Chatty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
        debugPanel.show()
        #else
        runInitialSetup()
        #endif
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
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Chatty"
        menu.addItem(NSMenuItem(title: appName, action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Set OpenAI API Key…", action: #selector(setAPIKey), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Speech Recognition…", action: #selector(editSpeechRecognition), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Sentence Cleanup…", action: #selector(editSentenceCleanup), keyEquivalent: ""))
        let vocabularyTitle = config.transcriptionPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? "Edit Transcription Vocabulary…"
            : "Set Transcription Vocabulary…"
        menu.addItem(NSMenuItem(title: vocabularyTitle, action: #selector(setTranscriptionVocabulary), keyEquivalent: ""))
        let toggleLabel = config.recordingShortcut?.label ?? "Double Left Shift"
        let toggleStatus = NSMenuItem(title: "\(toggleLabel) toggles recording", action: nil, keyEquivalent: "")
        toggleStatus.isEnabled = false
        menu.addItem(toggleStatus)
        menu.addItem(NSMenuItem(title: "Escape copies text and closes recording", action: nil, keyEquivalent: ""))

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
        #if CHATTY_DEBUG_PANEL
        menu.addItem(NSMenuItem(title: "Show Debug Panel…", action: #selector(showDebugPanel), keyEquivalent: ""))
        #endif
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    #if CHATTY_DEBUG_PANEL
    @objc private func showDebugPanel() {
        debugPanel.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        debugPanel.show()
        return true
    }
    #endif

    private func buildRecordingsMenu() -> NSMenu {
        let menu = NSMenu(title: "Recordings")
        menu.autoenablesItems = false
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
                submenu.autoenablesItems = false

                let openItem = NSMenuItem(title: "Open Recording", action: #selector(openRecording(_:)), keyEquivalent: "")
                openItem.representedObject = recording.id.uuidString
                submenu.addItem(openItem)

                if history.activeIDs.contains(recording.id) {
                    let item = NSMenuItem(title: "Transcribing…", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    submenu.addItem(item)
                } else if let transcript = recording.transcript, !transcript.isEmpty {
                    let item = NSMenuItem(title: "Transcript: \(preview(transcript))", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    submenu.addItem(item)

                    let copyItem = NSMenuItem(title: "Copy Transcript", action: #selector(copyTranscript(_:)), keyEquivalent: "")
                    copyItem.representedObject = recording.id.uuidString
                    copyItem.isEnabled = !dictation.isActive
                    submenu.addItem(copyItem)
                } else {
                    let item = NSMenuItem(title: "Transcribe Now", action: #selector(transcribeRecording(_:)), keyEquivalent: "")
                    item.representedObject = recording.id.uuidString
                    item.isEnabled = !dictation.isActive
                    submenu.addItem(item)
                }

                if let error = recording.transcriptionError, !error.isEmpty {
                    let errorItem = NSMenuItem(title: "Show Error: \(preview(error))", action: #selector(showRecordingError(_:)), keyEquivalent: "")
                    errorItem.representedObject = recording.id.uuidString
                    submenu.addItem(errorItem)

                    let retryItem = NSMenuItem(title: "Try Again", action: #selector(transcribeRecording(_:)), keyEquivalent: "")
                    retryItem.representedObject = recording.id.uuidString
                    retryItem.isEnabled = !dictation.isActive
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

    }

    @objc private func setAPIKey() {
        let alert = NSAlert()
        alert.messageText = "OpenAI API Key"
        alert.informativeText = "Stored in Keychain for this app."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "Enter a new API key"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                do {
                    guard !key.isEmpty else { throw TranscriptionError.missingAPIKey }
                    try await Task.detached { try KeychainStore.saveAPIKey(key) }.value
                    await openAICredentials.use(key)
                } catch {
                    showError(error.localizedDescription)
                }
            }
        }
    }

    @objc private func setRecordingShortcut() {
        shortcutCapture.begin(current: config.recordingShortcut) { [weak self] binding in
            self?.applyRecordingShortcut(binding)
        }
    }

    @objc private func editSentenceCleanup() {
        correctionSettingsWindow.show(settings: config.effectiveCorrectionSettings)
    }

    @objc private func setTranscriptionVocabulary() {
        let alert = NSAlert()
        alert.messageText = "Transcription Vocabulary"
        alert.informativeText = "Add context and spellings for OpenAI to use while transcribing. This is sent as the API prompt. For example: \"This dictation uses software terms: JSON (not Jason), AppKit, Swift Package Manager, and Chatty.\""
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 120))
        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.string = config.transcriptionPrompt ?? ""
        let scrollView = NSScrollView(frame: textView.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        alert.accessoryView = scrollView

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let prompt = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                config = try configStore.setTranscriptionPrompt(prompt.isEmpty ? nil : prompt)
                refreshMenu()
            } catch {
                showError(error.localizedDescription)
            }
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
        do {
            #if CHATTY_DEBUG_PANEL
            guard debugGlobalShortcuts else {
                shortcut.stop()
                try recordingHotkey.update(binding: nil)
                escapeShortcut.stop()
                return
            }
            #endif
            updateEscapeBinding()
            if let binding = config.recordingShortcut {
                shortcut.stop()
                try recordingHotkey.update(binding: binding)
            } else {
                try recordingHotkey.update(binding: nil)
                shortcut.start()
            }
        } catch { showError(error.localizedDescription) }
    }

    @objc private func showLastError() {
        guard let lastErrorMessage else { return }
        errorWindow.show(message: lastErrorMessage)
    }

    @objc private func openRecording(_ sender: NSMenuItem) {
        guard let recording = recording(from: sender) else { return }
        openInQuickTime(store.audioURL(for: recording))
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
        guard let recording = recording(from: sender) else { return }
        do { try history.copy(recording) } catch { showError(error.localizedDescription) }
    }

    @objc private func showRecordingError(_ sender: NSMenuItem) {
        guard let recording = recording(from: sender), let error = recording.transcriptionError else { return }
        errorWindow.show(message: error)
    }

    @objc private func clearRecordingError(_ sender: NSMenuItem) {
        guard let id = id(from: sender) else { return }
        do {
            try history.clearError(id)
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
            if !dictation.isActive { targetPasteApplication = NSWorkspace.shared.frontmostApplication }
            await dictation.toggle()
        }
    }

    private func handleEscape() {
        cancelOverlayAction()
    }

    private func cancelOverlayAction() {
        switch presentation.owner {
        case .dictation:
            Task { await dictation.cancel(); targetPasteApplication = nil }
        case .recording(let id): history.cancel(id)
        case .message, nil: dismissErrorUI()
        }
    }

    private func retryOverlayTranscription() {
        guard case .recording(let id) = presentation.owner else { return }
        do {
            guard let recording = try store.load().first(where: { $0.id == id }) else { return }
            history.retry(recording, prompt: config.transcriptionPrompt)
        } catch { showError(error.localizedDescription) }
    }

    private func updateEscapeBinding() {
        #if CHATTY_DEBUG_PANEL
        guard debugGlobalShortcuts else { escapeShortcut.stop(); return }
        #endif
        if dictation.isActive || !history.activeIDs.isEmpty {
            do { try escapeShortcut.start() } catch { showError(error.localizedDescription) }
        }
        else { escapeShortcut.stop() }
    }

    private func dismissErrorUI() {
        overlay.close()
        errorWindow.dismiss()
    }

    private func showError(_ message: String) {
        let session = presentation.session(for: .message)
        session.begin()
        session.showError(message)
        reportError(message)
    }

    private func reportError(_ message: String) {
        lastErrorMessage = message
        refreshMenu()
        errorWindow.show(message: message)
    }

    private func copyTextToClipboard(_ text: String) {
        #if CHATTY_DEBUG_PANEL
        harness!.recordCopy(text)
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func pasteTranscript() {
        #if CHATTY_DEBUG_PANEL
        guard harness!.systemPaste.target != nil else {
            harness!.pasteTarget.paste(from: harness!.pasteboard)
            return
        }
        do { targetPasteApplication = try harness!.systemPaste.stage(harness!.pasteboard.string(forType: .string)!) }
        catch { showError(error.localizedDescription); return }
        #endif
        let targetApplication = targetPasteApplication
        targetPasteApplication = nil
        targetApplication?.activate(options: [])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.pasteClipboardContents()
        }
    }

    private func pasteClipboardContents() {
        #if CHATTY_DEBUG_PANEL
        var posted = false
        defer { harness!.finishSystemPaste(posted: posted) }
        #endif
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
        #if CHATTY_DEBUG_PANEL
        posted = true
        #endif
    }

    private func transcribe(_ recording: Recording, pasteAfterCopy: Bool = false) {
        history.start(recording, prompt: config.transcriptionPrompt, paste: pasteAfterCopy)
    }
}

#if CHATTY_DEBUG_PANEL
if CommandLine.arguments.dropFirst().first == "--benchmark-asr" {
    Task { @MainActor in
        do {
            try await DebugASRBenchmark.run(Array(CommandLine.arguments.dropFirst(2)))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    RunLoop.main.run()
} else {
    let appDelegate = AppDelegate()
    NSApplication.shared.delegate = appDelegate
    NSApplication.shared.run()
}
#else
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
#endif
