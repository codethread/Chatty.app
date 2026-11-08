import AVFoundation
import CryptoKit
import XCTest

/// XCUI owns user actions. The authenticated API only supplies fixtures/faults
/// and observes state, posted HTTP payloads and real AppKit text storage.
@MainActor
final class DictationUITests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var app: XCUIApplication!
    private var client: HarnessClient!
    private var workspace: URL!
    private var destination: XCUIApplication?
    private var panel: XCUIElement { app.windows["Chatty Debug Panel"] }
    private var liveText: XCUIElement { app.textViews["Live transcript"] }

    override func setUp() async throws {
        // Async tests must finish their task before teardown touches the app.
        // Throw at workflow gates; collect ordinary value assertions in place.
        continueAfterFailure = true
        // Xcode's UI runner is sandboxed even when the target app is not.
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("ChattyUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        app = XCUIApplication(url: root.appendingPathComponent("build/Chatty UITest.app"))
        app.launchEnvironment = [
            "CHATTY_DEBUG_DIRECTORY": workspace.appendingPathComponent("data").path,
            "CHATTY_DEBUG_CONTROL_FILE": workspace.appendingPathComponent("control.json").path
        ]
        // Core UI contracts never initiate a network model download. Only the
        // explicit audio contract uses the developer's existing model cache.
        if !name.contains("testAudio") {
            app.launchEnvironment["CHATTY_DEBUG_MODEL_DIRECTORY"] = workspace.appendingPathComponent("Models").path
        }
        try await launchAndConnect()
    }

    override func tearDown() async throws {
        defer { destination?.terminate(); app?.terminate() }
        guard let client else { return }
        let data = try await client.request("/state")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Final harness state"; attachment.lifetime = .keepAlways
        add(attachment)
        // Reset cancels outstanding work and restores the staged test clipboard.
        try await client.command("reset")
    }

    private func launchAndConnect() async throws {
        app.launch()
        guard panel.waitForExistence(timeout: 15) else { throw HarnessError("Debug panel did not launch") }
        try await expect(panel.staticTexts["Harness connection"], "value CONTAINS %@", "control.json")
        client = try HarnessClient(controlFile: workspace.appendingPathComponent("control.json"))
        _ = try await client.wait(["phase": "idle"])
    }

    private func expect(_ element: XCUIElement, _ format: String, _ value: String, timeout: TimeInterval = 15) async throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: timeout)
        guard result == .completed else { throw HarnessError("UI expectation timed out: \(format) \(value)") }
    }

    private func replace(_ element: XCUIElement, with text: String) {
        element.click()
        element.typeKey("a", modifierFlags: .command)
        element.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
        if !text.isEmpty { element.typeText(text) }
    }

    private func select(_ popup: XCUIElement, _ title: String) {
        popup.click()
        app.menuItems[title].click()
    }

    private func start() async throws {
        app.activate()
        panel.buttons["Start dictation"].click()
        _ = try await client.wait(["phase": "listening"])
    }

    private func inject(_ committed: String, partial: String = "") {
        replace(panel.textViews["Dictation text"], with: committed)
        replace(panel.textFields["Injected provisional text"], with: partial)
        panel.buttons["Inject snapshot"].click()
    }

    private func stop() async throws -> HarnessState {
        app.activate()
        panel.buttons["Stop dictation"].click()
        return try await client.wait(["phase": "complete"])
    }

    private func audio(_ recording: HarnessState.Recording) throws -> Data {
        let url = client.directory.appendingPathComponent("Recordings/" + recording.audioFilename)
        let file = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(file.length, 0, "Saved AAC must decode and contain frames")
        return try Data(contentsOf: url)
    }

    private func lastReceipt() async throws -> HarnessReceipt {
        let page = try await client.decode(HarnessRequestPage.self, path: "/requests?limit=100")
        let summary = try XCTUnwrap(page.requests.last)
        return try await client.decode(HarnessReceipt.self, path: "/requests/" + summary.id)
    }

    func testStreamingQueueStopAndPersistence() async throws {
        select(panel.popUpButtons["Fake HTTP response"], "hold")
        try await start()
        inject("First sentence.", partial: "live tail")
        let active = try await client.wait(["requestCount": 1])
        try await expect(liveText, "value == %@", "First sentence. live tail")
        XCTAssertTrue(active.overlay.spans.contains { $0.kind == "active" })
        inject("First sentence. Second sentence.", partial: "live tail")
        let queued = try await client.wait(["textContains": "Second sentence."])
        XCTAssertEqual(queued.requestCount, 1, "Cleanup must serialize requests")
        XCTAssertTrue(queued.overlay.spans.contains { $0.kind == "pending" })
        select(panel.popUpButtons["Fake HTTP response"], "success")
        panel.buttons["Release HTTP replies"].click()
        _ = try await client.wait(["corrected": "FIRST_SENTENCE_SECOND_SENTENCE"])
        let state = try await stop()
        let expected = "FIRST_SENTENCE_SECOND_SENTENCE_LIVE_TAIL"
        XCTAssertEqual(state.copied, [expected]); XCTAssertEqual(state.completed, [expected])
        XCTAssertEqual(state.pasteTarget, expected)
        XCTAssertEqual(state.latestRecording?.transcript, expected)
        XCTAssertFalse(state.overlay.visible)
        _ = try audio(XCTUnwrap(state.latestRecording))
        app.terminate(); try await launchAndConnect()
        let reloaded = try await client.state()
        XCTAssertEqual(reloaded.latestRecording?.transcript, expected, "History must survive app relaunch")
    }

    func testCancelHeldReplyAndRestart() async throws {
        select(panel.popUpButtons["Fake HTTP response"], "hold")
        try await start(); inject("Old sentence.", partial: "old tail")
        _ = try await client.wait(["requestCount": 1])
        panel.buttons["Cancel"].click()
        let cancelled = try await client.wait(["phase": "idle"])
        XCTAssertEqual(cancelled.copied, ["Old sentence. old tail"])
        XCTAssertEqual(cancelled.recordingCount, 0)
        select(panel.popUpButtons["Fake HTTP response"], "success")
        try await start(); inject("New sentence.")
        panel.buttons["Release HTTP replies"].click()
        let state = try await stop()
        XCTAssertEqual(state.completed, ["NEW_SENTENCE"])
        XCTAssertEqual(state.pasteTarget, "NEW_SENTENCE")
    }

    func testPreparationCancelAndStopFailure() async throws {
        select(panel.popUpButtons["Input fault"], "Hold preparation")
        panel.buttons["Start dictation"].click()
        _ = try await client.wait(["phase": "preparing"])
        panel.buttons["Cancel"].click()
        _ = try await client.wait(["phase": "idle"])
        select(panel.popUpButtons["Input fault"], "No input fault")
        // Capture failure variants live in DictationControllerTests; this proves
        // the native Stop action and error presentation remain connected.
        try await start(); inject("Preserve this recording.")
        select(panel.popUpButtons["Input fault"], "Fail Stop")
        panel.buttons["Stop dictation"].click()
        let failed = try await client.wait(["phase": "failed"])
        XCTAssertTrue(failed.overlay.visible)
        XCTAssertTrue(failed.overlay.status.hasPrefix("Error:"))
        XCTAssertTrue(liveText.exists)
        XCTAssertTrue(failed.completed.isEmpty)
        XCTAssertEqual(failed.recordingCount, 1)
        _ = try audio(XCTUnwrap(failed.latestRecording))
    }

    func testCleanupFailureKeepsAudioAndNeverPastesPartialText() async throws {
        // One real HTTP failure proves app wiring; the full response/transport
        // matrix exercises the controller, production client and files below UI.
        try await start(); inject("First sentence.")
        _ = try await client.wait(["corrected": "FIRST_SENTENCE"])
        select(panel.popUpButtons["Fake HTTP response"], "incomplete")
        inject("First sentence. Second sentence.")
        let failed = try await client.wait(["phase": "failed"])
        XCTAssertTrue(failed.completed.isEmpty)
        XCTAssertTrue(failed.copied.isEmpty)
        XCTAssertEqual(failed.pasteTarget, "")
        XCTAssertEqual(failed.recordingCount, 1)
        XCTAssertNotNil(failed.latestRecording?.transcriptionError)
        XCTAssertTrue(failed.overlay.visible)
        XCTAssertTrue(failed.overlay.status.hasPrefix("Error:"))
        XCTAssertTrue(liveText.exists)
        XCTAssertTrue(failed.overlay.canCancel)
        _ = try audio(XCTUnwrap(failed.latestRecording))
    }

    func testSavedRecordingUploadRetryCancelAndCopy() async throws {
        try await start(); inject("Original sentence.")
        let saved = try await stop()
        let recording = try XCTUnwrap(saved.latestRecording)
        let bytes = try audio(recording)
        select(panel.popUpButtons["Fake HTTP response"], "unauthorized")
        panel.buttons["Transcribe / Retry"].click()
        let failed = try await client.wait(["historyID": recording.id, "historyPhase": "failed"])
        XCTAssertNotNil(failed.latestRecording?.transcriptionError)
        select(panel.popUpButtons["Fake HTTP response"], "success")
        panel.buttons["Transcribe / Retry"].click()
        let retried = try await client.wait(["historyID": recording.id, "historyPhase": "complete"])
        XCTAssertNil(retried.latestRecording?.transcriptionError)
        let receipt = try await lastReceipt()
        XCTAssertEqual(receipt.path, "/v1/audio/transcriptions")
        XCTAssertEqual(receipt.audioBytes, bytes.count)
        XCTAssertEqual(receipt.audioSHA256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        panel.buttons["Copy saved transcript"].click()
        let copied = try await client.state()
        XCTAssertEqual(copied.copied.last, retried.latestRecording?.transcript)
        select(panel.popUpButtons["Fake HTTP response"], "hold")
        panel.buttons["Transcribe / Retry"].click()
        _ = try await client.wait(["historyID": recording.id, "historyPhase": "transcribing"])
        panel.buttons["Cancel upload"].click()
        _ = try await client.wait(["historyID": recording.id, "historyPhase": "cancelled"])
        select(panel.popUpButtons["Fake HTTP response"], "success")
        try await start(); inject("Live dictation.")
        panel.buttons["Release HTTP replies"].click()
        let final = try await stop()
        XCTAssertEqual(final.completed.last, "LIVE_DICTATION")
        XCTAssertEqual(final.pasteTarget, saved.pasteTarget + "LIVE_DICTATION")
    }

    func testCleanupSettingsValidationCancelResetAndPayload() async throws {
        let initial = try await client.state().settings
        XCTAssertTrue(initial.tapeEnabled)
        XCTAssertTrue(initial.tapePrompt.contains("remove the last sentence"))
        panel.buttons["Sentence cleanup…"].click()
        let settings = app.windows["Sentence Cleanup"]
        let tapeToggle = settings.checkBoxes["Enable for the tape instructions"]
        let tapeEditor = settings.textViews["For the tape instructions"]
        XCTAssertEqual(tapeToggle.value as? Int, 1)
        XCTAssertEqual(tapeEditor.value as? String, initial.tapePrompt)
        replace(settings.textFields["Context lines"], with: "0")
        settings.buttons["Save"].click()
        XCTAssertTrue(settings.exists)
        try await expect(settings.staticTexts["Settings validation"], "value != %@", "")
        replace(settings.textFields["Context lines"], with: "3")
        replace(tapeEditor, with: "")
        settings.buttons["Save"].click()
        XCTAssertTrue(settings.exists)
        try await expect(settings.staticTexts["Settings validation"], "value CONTAINS %@", "for the tape")
        settings.buttons["Cancel"].click()
        let cancelled = try await client.state()
        XCTAssertEqual(cancelled.settings, initial)
        panel.buttons["Sentence cleanup…"].click()
        replace(settings.textFields["Context lines"], with: "5")
        replace(settings.textViews["Cleanup instructions"], with: "Keep the original tone.")
        let customTapePrompt = "Requests addressed to the editor combine the last two sentences."
        replace(tapeEditor, with: customTapePrompt)
        replace(settings.textViews["Word dictionary"], with: "jason = JSON\nopen ai = OpenAI")
        settings.buttons["Save"].click()
        XCTAssertFalse(settings.exists)
        app.terminate(); try await launchAndConnect()
        let reloaded = try await client.state()
        XCTAssertEqual(reloaded.settings.contextLines, 5)
        XCTAssertEqual(reloaded.settings.dictionary["jason"], "JSON")
        XCTAssertTrue(reloaded.settings.tapeEnabled)
        XCTAssertEqual(reloaded.settings.tapePrompt, customTapePrompt)
        try await start(); inject("Use jason with open ai.")
        _ = try await stop()
        let receipt = try await lastReceipt()
        XCTAssertTrue(receipt.instructions?.contains("Keep the original tone.") == true)
        XCTAssertTrue(receipt.instructions?.contains("JSON") == true)
        XCTAssertTrue(receipt.instructions?.contains(customTapePrompt) == true)
        XCTAssertFalse(receipt.instructions?.contains(initial.tapePrompt) == true)
        XCTAssertTrue(receipt.input?.contains("Use jason with open ai.") == true)
        panel.buttons["Sentence cleanup…"].click()
        tapeToggle.click()
        XCTAssertEqual(tapeToggle.value as? Int, 0)
        settings.buttons["Save"].click()
        app.terminate(); try await launchAndConnect()
        let disabled = try await client.state()
        XCTAssertFalse(disabled.settings.tapeEnabled)
        XCTAssertEqual(disabled.settings.tapePrompt, customTapePrompt)
        panel.buttons["Sentence cleanup…"].click()
        XCTAssertEqual(tapeToggle.value as? Int, 0)
        XCTAssertEqual(tapeEditor.value as? String, customTapePrompt)
        settings.buttons["Cancel"].click()
        try await start(); inject("For the tape, keep these words.")
        _ = try await stop()
        let disabledReceipt = try await lastReceipt()
        XCTAssertFalse(disabledReceipt.instructions?.contains(customTapePrompt) == true)
        XCTAssertFalse(disabledReceipt.instructions?.contains("For the tape instructions:") == true)
        XCTAssertTrue(disabledReceipt.instructions?.contains("Spoken editing requests are disabled") == true)
        panel.buttons["Sentence cleanup…"].click()
        settings.buttons["Reset to Defaults"].click()
        XCTAssertEqual(tapeToggle.value as? Int, 1)
        XCTAssertEqual(tapeEditor.value as? String, initial.tapePrompt)
        settings.buttons["Cancel"].click()
        let resetCancelled = try await client.state()
        XCTAssertEqual(resetCancelled.settings, disabled.settings)
        panel.buttons["Sentence cleanup…"].click()
        settings.buttons["Reset to Defaults"].click()
        settings.buttons["Save"].click()
        let resetSaved = try await client.state()
        XCTAssertEqual(resetSaved.settings, initial)
    }

    func testSpeechSettingsDefaultCancelAndMissingModel() async throws {
        let initial = try await client.state()
        XCTAssertEqual(initial.speechEngine, "apple")
        panel.buttons["Speech recognition…"].click()
        let speech = app.windows["Speech Recognition"]
        XCTAssertEqual(speech.popUpButtons["Speech recognition engine"].value as? String, "Apple · built in")
        select(speech.popUpButtons["Speech recognition engine"], "Nemotron 600M · local streaming")
        speech.buttons["Save"].click()
        try await expect(speech.staticTexts["Speech settings validation"], "value CONTAINS %@", "Download")
        XCTAssertTrue(speech.buttons["Download local model"].isEnabled)
        speech.buttons["Cancel"].click()
        let cancelled = try await client.state()
        XCTAssertEqual(cancelled.speechEngine, "apple")
        app.terminate(); try await launchAndConnect()
        let reloaded = try await client.state()
        XCTAssertEqual(reloaded.speechEngine, "apple")
    }

    func testExternalApplicationPasteAndClipboardRestoration() async throws {
        let permissions = try await client.state()
        guard permissions.platform["accessibility"] == "true" else {
            throw HarnessError("Enable the current build/Chatty UITest.app in System Settings → Privacy & Security → Accessibility. Ad-hoc rebuilds can invalidate that grant; rerun with --no-build after reauthorizing. UI Automation authorization is separate.")
        }
        let target = XCUIApplication(url: root.appendingPathComponent("build/UITests/Build/Products/Debug/ChattyPasteTarget.app"))
        destination = target; target.launch()
        let editor = target.textViews["paste.destination"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        try await client.command("systemPaste", ["value": "local.chatty.ChattyPasteTarget"])
        let before = try await client.state().systemPasteDispatches
        try await start(); inject("Paste into the other app.")
        let completed = try await stop()
        _ = try await client.wait(["systemPasteDispatches": before + 1])
        try await expect(editor, "value == %@", "PASTE_INTO_THE_OTHER_APP")
        XCTAssertEqual(completed.completed, ["PASTE_INTO_THE_OTHER_APP"])
        try await client.command("restoreClipboard")
        let restored = try await client.state()
        XCTAssertTrue(restored.clipboardRestored)
    }

    func testCrossApplicationShortcutAndEscape() async throws {
        try await client.command("ui", ["view": "shortcut", "show": true])
        let capture = app.windows["Set Recording Shortcut"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.typeKey("9", modifierFlags: [.control, .option, .command])
        XCTAssertFalse(capture.exists)
        try await client.command("globals", ["enabled": true])
        let registered = try await client.state()
        XCTAssertEqual(registered.platform["recordingHotkey"], "true")
        let target = XCUIApplication(url: root.appendingPathComponent("build/UITests/Build/Products/Debug/ChattyPasteTarget.app"))
        destination = target; target.launch(); target.activate()
        target.typeKey("9", modifierFlags: [.control, .option, .command])
        _ = try await client.wait(["phase": "listening"])
        try await client.command("inject", ["committed": "Escape this sentence.", "partial": "visible tail"])
        try await expect(liveText, "value CONTAINS %@", "visible tail")
        target.activate(); target.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let cancelled = try await client.wait(["phase": "idle"])
        XCTAssertEqual(cancelled.recordingCount, 0)
        XCTAssertTrue(cancelled.completed.isEmpty)
        XCTAssertTrue(cancelled.copied.last?.contains("visible tail") == true)
    }

    func testAudioEngineSwitchAppliesToNextSession() async throws {
        let model = try await client.state().model
        guard ["downloaded", "ready"].contains(model.phase) else {
            throw HarnessError("Download the fixed model using debug Speech Recognition settings before running the audio workflow (--with-audio).")
        }
        panel.buttons["Speech recognition…"].click()
        let speech = app.windows["Speech Recognition"]
        if model.phase != "ready" {
            speech.buttons["Download local model"].click()
            _ = try await client.wait(["modelPhase": "ready", "timeoutSeconds": 120])
        }
        select(speech.popUpButtons["Speech recognition engine"], "Nemotron 600M · local streaming")
        speech.buttons["Save"].click()
        app.terminate(); try await launchAndConnect()
        let reloaded = try await client.state()
        XCTAssertEqual(reloaded.speechEngine, "nemotron")
        let fixture = root.appendingPathComponent("Tests/Fixtures/statements-with-pauses.wav")
        try await client.command("selectAudioFile", ["audioPath": fixture.path])
        try await start()
        panel.buttons["Speech recognition…"].click()
        select(speech.popUpButtons["Speech recognition engine"], "Apple · built in")
        speech.buttons["Save"].click()
        let local = try await client.wait(["phase": "complete", "timeoutSeconds": 60])
        XCTAssertEqual(local.recognitionEngine, "nemotron")
        XCTAssertEqual(local.speechEngine, "apple")
        XCTAssertEqual(local.completed, ["THIS_IS_A_STATEMENT_WITHOUT_A_QUESTION_NOW_I_AM_STARTING_ANOTHER_TOPIC"])
        XCTAssertGreaterThanOrEqual(local.requestCount, 2, "Silence should close the first sentence before capture ends")
        _ = try audio(XCTUnwrap(local.latestRecording))
        try await start()
        let apple = try await client.wait(["phase": "complete", "timeoutSeconds": 60])
        XCTAssertEqual(apple.recognitionEngine, "apple")
        XCTAssertTrue(apple.completed.last?.contains("STATEMENT_WITHOUT_A_QUESTION") == true)
        XCTAssertTrue(apple.completed.last?.contains("STARTING_ANOTHER_TOPIC") == true)
        XCTAssertEqual(apple.latestRecording?.transcript, apple.completed.last)
        XCTAssertEqual(apple.pasteTarget, local.pasteTarget + (try XCTUnwrap(apple.completed.last)))
    }
}
