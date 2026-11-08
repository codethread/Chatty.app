#if CHATTY_DEBUG_PANEL
import AppKit
import Foundation

@MainActor
enum DebugEnvironment {
    static let directory: URL = {
        if let path = ProcessInfo.processInfo.environment["CHATTY_DEBUG_DIRECTORY"] {
            precondition(path.hasPrefix("/"), "CHATTY_DEBUG_DIRECTORY must be absolute")
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let production = RecordingStore.defaultDirectory.resolvingSymlinksInPath()
            precondition(!url.path.hasPrefix(production.path + "/") && url != production,
                         "The debug workspace must be separate from production data")
            return url
        }
        return RecordingStore.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("Chatty Debug", isDirectory: true)
    }()
    static let modelRoot: URL = {
        if let path = ProcessInfo.processInfo.environment["CHATTY_DEBUG_MODEL_DIRECTORY"] {
            precondition(path.hasPrefix("/"), "CHATTY_DEBUG_MODEL_DIRECTORY must be absolute")
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return LocalSpeechRecognizer.defaultModelRoot
    }()
    static let controlFile: URL = {
        if let path = ProcessInfo.processInfo.environment["CHATTY_DEBUG_CONTROL_FILE"] {
            precondition(path.hasPrefix("/"), "CHATTY_DEBUG_CONTROL_FILE must be absolute")
            return URL(fileURLWithPath: path)
        }
        return directory.appendingPathComponent("control.json")
    }()
}

@MainActor
final class DebugHarness {
    struct ConnectionInfo: Codable, Sendable {
        let url: URL
        let token: String
        let pid: Int32
        let directory: URL
    }
    struct Snapshot: Codable, Sendable {
        let phase: String
        let failure: String?
        let raw: TranscriptSnapshot
        let corrected: String
        let pending: String
        let tail: String
        let text: String
        let copied: [String]
        let completed: [String]
        let pasteTarget: String
        let overlay: OverlayDebugSnapshot
        let recordingCount: Int
        let latestRecording: Recording?
        let storageError: String?
        let requestCount: Int
        let settings: CorrectionSettings
        let directory: URL
        let globalShortcuts: Bool
        let history: [String: RecordingTranscriptionController.State]
        let platform: [String: String]
        let speechEngine: SpeechRecognitionEngine
        let model: LocalSpeechRecognizer.ModelState
        let recognitionEngine: SpeechRecognitionEngine?
        let systemPasteTarget: String?
        let clipboardNeedsRestore: Bool
        let clipboardRestored: Bool
        let systemPasteDispatches: Int
    }
    struct Condition: Codable, Sendable {
        var phase: String?
        var textContains: String?
        var corrected: String?
        var requestCount: Int?
        var recordingCount: Int?
        var historyID: UUID?
        var historyPhase: RecordingTranscriptionController.State.Phase?
        var modelPhase: LocalSpeechRecognizer.ModelState.Phase?
        var timeoutSeconds: Int?
        var systemPasteDispatches: Int?
    }
    struct Command: Decodable {
        enum Action: String, Decodable {
            case start, stop, cancel, toggle, inject, level, inputFailure, inputFaults, releasePreparation
            case fake, releaseRequests, settings, reset, showPasteTarget, clearPasteTarget, globals, selectAudioFile, replayAudio, render, quit
            case transcribeRecording, cancelTranscription, retryTranscription, copyRecording, clearRecordingError
            case ui, vocabulary
            case shortcutKey, resetShortcut, nativeHotkey
            case systemPaste, restoreClipboard
        }
        let action: Action
        var committed: String?
        var partial: String?
        var level: Float?
        var bytes: Int64?
        var behavior: FakeOpenAI.Behavior?
        var audioText: String?
        var holdPreparation: Bool?
        var failStart: Bool?
        var failStop: Bool?
        var failCancel: Bool?
        var prompt: String?
        var dictionary: String?
        var contextLines: String?
        var tapeEnabled: Bool?
        var tapePrompt: String?
        var clearData: Bool?
        var enabled: Bool?
        var audioPath: String?
        var view: String?
        var recordingID: UUID?
        var paste: Bool?
        var control: String?
        var value: String?
        var click: Bool?
        var show: Bool?
        var keyCode: UInt16?
        var modifiers: [String]?
    }

    let input: DebugDictationInputService
    let corrector: DebugTranscriptCorrector
    let controller: DictationController
    let fake: FakeOpenAI
    let store: RecordingStore
    let configStore: ConfigStore
    let history: RecordingTranscriptionController
    private let corrections: CorrectionController
    private let overlay: OverlayWindowController
    private let server = LocalHTTPServer()
    private let token = UUID().uuidString
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var eventTasks: [Task<Void, Never>] = []
    private(set) var connection: ConnectionInfo?
    private(set) var copied: [String] = []
    private(set) var completed: [String] = []
    let pasteboard = NSPasteboard.withUniqueName()
    let pasteTarget = DebugPasteTarget()
    let systemPaste = DebugSystemPaste()
    let recognizer: LocalSpeechRecognizer
    var onSettings: ((AppConfig) -> Void)?
    var onReset: (() -> Void)?
    var onGlobalShortcuts: ((Bool) -> Void)?
    var onChange: (() -> Void)?
    var renderPanel: ((URL) throws -> Void)?
    var uiWindow: ((String, Bool) throws -> NSWindow)?
    var platformState: (() -> [String: String])?
    var shortcutKey: ((UInt16, NSEvent.ModifierFlags, String) throws -> Void)?
    var resetShortcut: (() -> Void)?
    private(set) var globalShortcuts = false

    init(input: DebugDictationInputService, corrector: DebugTranscriptCorrector, controller: DictationController,
         fake: FakeOpenAI, store: RecordingStore, configStore: ConfigStore,
         corrections: CorrectionController, overlay: OverlayWindowController, history: RecordingTranscriptionController, recognizer: LocalSpeechRecognizer) {
        self.input = input; self.corrector = corrector; self.controller = controller; self.fake = fake
        self.store = store; self.configStore = configStore; self.corrections = corrections; self.overlay = overlay
        self.history = history
        self.recognizer = recognizer
    }

    func start() async throws {
        let url = try await server.start { [weak self] request in
            guard let self else { return LocalHTTPResponse(status: 503) }
            return await self.handle(request)
        }
        let connection = ConnectionInfo(url: url, token: token, pid: ProcessInfo.processInfo.processIdentifier, directory: store.appDirectory)
        self.connection = connection
        try FileManager.default.createDirectory(at: DebugEnvironment.controlFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(connection).write(to: DebugEnvironment.controlFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: DebugEnvironment.controlFile.path)
        let modelChanges = await recognizer.changes()
        eventTasks.append(Task { [weak self] in for await _ in modelChanges { self?.changed() } })
        let coreChanges = controller.changes()
        let apiChanges = await fake.changes()
        let historyChanges = history.changes()
        eventTasks.append(Task { [weak self] in for await _ in coreChanges { self?.changed() } })
        eventTasks.append(Task { [weak self] in for await _ in apiChanges { self?.changed() } })
        eventTasks.append(Task { [weak self] in for await _ in historyChanges { self?.changed() } })
        corrector.log("Local harness ready · \(url.absoluteString)\nSandbox: \(store.appDirectory.path)\nConnection file: \(DebugEnvironment.controlFile.path)")
        FileHandle.standardOutput.write(Data(("CHATTY_HARNESS_READY " + DebugEnvironment.controlFile.path + "\n").utf8))
    }

    func finishSystemPaste(posted: Bool) {
        systemPaste.finishDispatch(posted: posted)
        changed()
    }

    func recordCopy(_ text: String) {
        copied.append(text)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        changed()
    }

    func recordCompletion(_ text: String) {
        completed.append(text)
        changed()
    }

    func snapshot() async -> Snapshot {
        var recordings: [Recording] = []
        var storageError: String?
        do { recordings = try store.load() } catch { storageError = error.localizedDescription }
        return Snapshot(phase: controller.phase.name, failure: controller.phase.failure,
                        raw: controller.transcript, corrected: controller.correctionState.correctedText,
                        pending: controller.correctionState.pendingText, tail: controller.correctionState.tail,
                        text: controller.correctionState.text, copied: copied, completed: completed,
                        pasteTarget: pasteTarget.text, overlay: overlay.debugSnapshot,
                        recordingCount: recordings.count, latestRecording: recordings.first, storageError: storageError,
                        requestCount: await fake.receipts.count, settings: corrections.settings, directory: store.appDirectory,
                        globalShortcuts: globalShortcuts,
                        history: Dictionary(uniqueKeysWithValues: history.states.map { ($0.key.uuidString, $0.value) }),
                        platform: platformState?() ?? [:], speechEngine: input.configured.backend, model: await recognizer.modelState(),
                        recognitionEngine: input.source == .audioFile ? input.audioFile.recognitionEngine : input.configured.recognitionEngine,
                        systemPasteTarget: systemPaste.targetID, clipboardNeedsRestore: systemPaste.needsRestore,
                        clipboardRestored: systemPaste.restoredClipboard, systemPasteDispatches: systemPaste.dispatchCount)
    }

    struct Acknowledgment: Encodable { let accepted: String; let artifact: URL? }

    @discardableResult
    func execute(_ command: Command) async throws -> Acknowledgment {
        var artifact: URL?
        switch command.action {
        case .start:
            guard !controller.isActive else { throw DebugInputError.injected("Dictation is already active") }
            Task { await controller.start() }
        case .stop: Task { await controller.stop() }
        case .cancel: Task { await controller.cancel() }
        case .toggle: Task { await controller.toggle() }
        case .inject:
            guard input.source == .injected else { throw DebugInputError.injected("Select injected input") }
            try input.injected.inject(.init(committedText: command.committed ?? "", partialText: command.partial ?? ""))
        case .level:
            let level = command.level ?? 0
            guard (0...1).contains(level), (command.bytes ?? 0) >= 0 else { throw DebugInputError.injected("Invalid level or file size") }
            try input.injected.injectLevel(level, fileSize: command.bytes ?? 0)
        case .inputFailure: try input.injected.injectFailure()
        case .inputFaults:
            input.injected.holdPreparation = command.holdPreparation ?? false
            input.injected.failStart = command.failStart ?? false
            input.injected.failStop = command.failStop ?? false
            input.injected.failCancel = command.failCancel ?? false
        case .releasePreparation: await input.injected.releasePreparation()
        case .fake:
            guard let behavior = command.behavior else { throw DebugInputError.injected("Supply fake behavior") }
            await fake.configure(behavior: behavior, audioText: command.audioText)
        case .releaseRequests: await fake.release()
        case .settings:
            let settings = try CorrectionSettings.parse(prompt: command.prompt ?? CorrectionSettings.defaultPrompt,
                                                        dictionaryText: command.dictionary ?? "",
                                                        contextLinesText: command.contextLines ?? "3",
                                                        tapeEnabled: command.tapeEnabled ?? true,
                                                        tapePrompt: command.tapePrompt ?? CorrectionSettings.defaultTapePrompt)
            let config = try configStore.setCorrectionSettings(settings)
            corrections.settings = settings
            onSettings?(config)
        case .vocabulary:
            let config = try configStore.setTranscriptionPrompt(command.value)
            onSettings?(config)
        case .ui:
            guard let uiWindow else { throw DebugInputError.injected("UI is not ready") }
            let window = try uiWindow(command.view ?? "panel", command.show ?? false)
            if let control = command.control {
                try DebugUI.interact(window, control: control, value: command.value, click: command.click ?? false)
            }
        case .reset:
            try systemPaste.restore()
            await controller.cancel()
            history.cancelAll()
            await fake.reset()
            globalShortcuts = false
            onGlobalShortcuts?(false)
            copied.removeAll(); completed.removeAll(); pasteTarget.clear()
            input.source = .injected; corrector.backend = .fake
            input.injected.holdPreparation = false; input.injected.failStart = false
            input.injected.failStop = false; input.injected.failCancel = false
            if command.clearData == true {
                for recording in try store.load() { try FileManager.default.removeItem(at: store.audioURL(for: recording)) }
                let metadata = store.appDirectory.appendingPathComponent("recordings.json")
                if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
            }
            onReset?()
        case .showPasteTarget: pasteTarget.show()
        case .clearPasteTarget: pasteTarget.clear()
        case .globals:
            globalShortcuts = command.enabled ?? false
            onGlobalShortcuts?(globalShortcuts)
        case .systemPaste:
            guard !controller.isActive else { throw DebugInputError.injected("Arm system paste before starting dictation") }
            try systemPaste.arm(bundleID: command.value)
        case .restoreClipboard: try systemPaste.restore()
        case .resetShortcut: resetShortcut?()
        case .shortcutKey:
            guard let code = command.keyCode, let shortcutKey else { throw DebugInputError.injected("Supply keyCode") }
            var flags = NSEvent.ModifierFlags()
            for modifier in command.modifiers ?? [] {
                switch modifier {
                case "command": flags.insert(.command)
                case "control": flags.insert(.control)
                case "option": flags.insert(.option)
                case "shift": flags.insert(.shift)
                default: throw DebugInputError.injected("Unknown key modifier")
                }
            }
            try shortcutKey(code, flags, command.value ?? "")
        case .nativeHotkey:
            guard globalShortcuts, let id = command.keyCode else { throw DebugInputError.injected("Enable native shortcuts and supply keyCode 1 or 2") }
            try DebugHotkeyEvent.send(id: UInt32(id))
        case .transcribeRecording, .cancelTranscription, .retryTranscription, .copyRecording, .clearRecordingError:
            if controller.isActive && [.transcribeRecording, .retryTranscription, .copyRecording].contains(command.action) {
                throw DebugInputError.injected("Finish dictation before opening a saved transcript")
            }
            guard let id = command.recordingID, let recording = try store.load().first(where: { $0.id == id }) else {
                throw DebugInputError.injected("Supply a recordingID from saved history")
            }
            switch command.action {
            case .transcribeRecording: history.start(recording, prompt: try configStore.load().transcriptionPrompt, paste: command.paste ?? false)
            case .cancelTranscription: history.cancel(id)
            case .retryTranscription: history.retry(recording, prompt: try configStore.load().transcriptionPrompt)
            case .copyRecording: try history.copy(recording)
            case .clearRecordingError: try history.clearError(id)
            default: break
            }
        case .selectAudioFile, .replayAudio:
            guard !controller.isActive, let path = command.audioPath, path.hasPrefix("/") else {
                throw DebugInputError.injected("Supply an absolute audioPath while idle")
            }
            input.audioFile.audioURL = URL(fileURLWithPath: path)
            input.source = .audioFile
            if command.action == .replayAudio { Task { await controller.start() } }
        case .render:
            let name = command.view ?? "overlay"
            let url = store.appDirectory.appendingPathComponent("Artifacts/\(name)-\(UUID().uuidString).png")
            switch name {
            case "overlay": try overlay.renderDebugView(to: url)
            case "panel":
                guard let renderPanel else { throw DebugInputError.injected("The panel is not ready to render") }
                try renderPanel(url)
            case "settings", "paste", "shortcut", "speech":
                guard let uiWindow else { throw DebugInputError.injected("UI is not ready") }
                let window = try uiWindow(name, false)
                try DebugViewRendering.writePNG(of: window.contentView!, background: window.backgroundColor, to: url)
            default: throw DebugInputError.injected("Render view must be panel, overlay, settings, paste or shortcut")
            }
            artifact = url
        case .quit:
            try systemPaste.restore()
            await controller.cancel()
            history.cancelAll()
        }
        changed()
        return Acknowledgment(accepted: command.action.rawValue, artifact: artifact)
    }

    private func handle(_ request: LocalHTTPRequest) async -> LocalHTTPResponse {
        guard request.headers["x-chatty-debug-token"] == token else { return LocalHTTPResponse(status: 401) }
        do {
            switch (request.method, request.path) {
            case ("GET", "/state"): return try .json(await snapshot())
            case ("GET", let path) where path.hasPrefix("/ui/"):
                guard let uiWindow else { throw DebugInputError.injected("UI is not ready") }
                return try .json(DebugUI.snapshot(uiWindow(String(path.dropFirst(4)), false)))
            case ("GET", "/requests"):
                let receipts = await fake.receipts
                struct Summary: Encodable { let id: String; let path: String; let model: String; let behavior: FakeOpenAI.Behavior }
                struct Page: Encodable { let requests: [Summary]; let total: Int; let nextOffset: Int? }
                let query = URLComponents(string: "http://localhost\(request.target)")?.queryItems ?? []
                let offset = Int(query.first { $0.name == "offset" }?.value ?? "0") ?? -1
                let limit = Int(query.first { $0.name == "limit" }?.value ?? "20") ?? -1
                guard offset >= 0, (1...100).contains(limit) else { throw DebugInputError.injected("Invalid request pagination") }
                let page = receipts.dropFirst(offset).prefix(limit)
                return try .json(Page(requests: page.map { Summary(id: $0.id, path: $0.path, model: $0.model, behavior: $0.behavior) },
                                      total: receipts.count, nextOffset: offset + page.count < receipts.count ? offset + page.count : nil))
            case ("GET", let path) where path.hasPrefix("/requests/"):
                let id = String(path.dropFirst("/requests/".count))
                guard let receipt = await fake.receipts.first(where: { $0.id == id }) else { return LocalHTTPResponse(status: 404) }
                return try .json(receipt)
            case ("POST", "/command"):
                let command = try JSONDecoder().decode(Command.self, from: request.body)
                var response = try LocalHTTPResponse.json(try await execute(command))
                if command.action == .quit {
                    response.onSent = { await MainActor.run { NSApplication.shared.terminate(nil) } }
                }
                return response
            case ("POST", "/wait"):
                let condition = try JSONDecoder().decode(Condition.self, from: request.body)
                return try .json(try await wait(for: condition))
            default: return LocalHTTPResponse(status: 404)
            }
        } catch { return try! .json(["error": error.localizedDescription], status: 400) }
    }

    private func wait(for condition: Condition) async throws -> Snapshot {
        let seconds = condition.timeoutSeconds ?? 15
        guard (1...900).contains(seconds) else { throw DebugInputError.injected("Wait timeout must be 1–900 seconds") }
        return try await withThrowingTaskGroup(of: Snapshot.self) { group in
            group.addTask { try await self.observe(condition) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw DebugInputError.injected("Timed out waiting for harness state")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func observe(_ condition: Condition) async throws -> Snapshot {
        for await _ in changes() {
            try Task.checkCancellation()
            let state = await snapshot()
            if (condition.phase == nil || state.phase == condition.phase) &&
               (condition.textContains == nil || state.text.contains(condition.textContains!)) &&
               (condition.corrected == nil || state.corrected == condition.corrected) &&
               (condition.requestCount == nil || state.requestCount >= condition.requestCount!) &&
               (condition.recordingCount == nil || state.recordingCount == condition.recordingCount) &&
               (condition.historyID == nil || state.history[condition.historyID!.uuidString]?.phase == condition.historyPhase) &&
               (condition.modelPhase == nil || state.model.phase == condition.modelPhase) &&
               (condition.systemPasteDispatches == nil || state.systemPasteDispatches >= condition.systemPasteDispatches!) { return state }
        }
        throw CancellationError()
    }

    private func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in self?.observers.removeValue(forKey: id) }
            }
        }
    }

    private func changed() {
        for observer in observers.values { observer.yield(()) }
        onChange?()
    }
}

extension DictationController.Phase {
    var name: String {
        switch self {
        case .idle: "idle"
        case .preparing: "preparing"
        case .listening: "listening"
        case .finishing: "finishing"
        case .complete: "complete"
        case .failed: "failed"
        }
    }
    var failure: String? { if case .failed(let message) = self { message } else { nil } }
}

@MainActor
final class DebugPasteTarget: NSWindowController {
    private let editor = NSTextView()
    var text: String { editor.string }
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Chatty Test Paste Target"
        editor.isRichText = false
        editor.font = .systemFont(ofSize: 16)
        editor.setAccessibilityLabel("Test paste destination")
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true; scroll.documentView = editor
        window.contentView = scroll
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func paste(from pasteboard: NSPasteboard) { _ = editor.readSelection(from: pasteboard, type: .string) }
    func clear() { editor.string = "" }
    func show() { showWindow(nil); window?.makeKeyAndOrderFront(nil) }
}
#endif
