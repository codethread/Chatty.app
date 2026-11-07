#!/usr/bin/env python3
"""Verify the running AppKit debug app through observed state and real HTTP."""
import argparse
import importlib.util
import json
import os
import selectors
import subprocess
import tempfile
import time
from pathlib import Path
import sys
import traceback

spec = importlib.util.spec_from_file_location("chatty_debug", Path(__file__).with_name("chatty-debug.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def require(value, message):
    if not value:
        raise AssertionError(message)


def verify(client, with_audio=False):
    results = []

    def run(name, scenario):
        client.command("reset", clearData=True)
        client.wait(phase="idle")
        try:
            evidence = scenario()
            results.append({"name": name, "passed": True, "evidence": evidence})
        except Exception as error:
            results.append({"name": name, "passed": False, "error": str(error), "traceback": traceback.format_exc(), "state": client.state()})

    def start():
        client.command("start")
        return client.wait(phase="listening")

    def stop():
        client.command("stop")
        return client.wait(phase="complete")

    def held_cleanup():
        client.command("fake", behavior="hold")
        start()
        client.command("inject", committed="First sentence.", partial="live tail")
        active = client.wait(requestCount=1)
        require(active["overlay"]["visible"], "Overlay did not open")
        require(active["overlay"]["text"] == "First sentence. live tail", "Live overlay text differs from input")
        require(any(s["kind"] == "active" for s in active["overlay"]["spans"]), "No blue active request highlight")
        client.command("inject", committed="First sentence. Second sentence.", partial="live tail")
        queued = client.wait(textContains="Second sentence.")
        require(queued["requestCount"] == 1, "Cleanup ran concurrently instead of queuing")
        require(any(s["kind"] == "pending" for s in queued["overlay"]["spans"]), "Queued speech is not highlighted")
        client.command("fake", behavior="success")
        client.command("releaseRequests")
        client.wait(corrected="FIRST_SENTENCE_SECOND_SENTENCE")
        completed = stop()
        expected = "FIRST_SENTENCE_SECOND_SENTENCE_LIVE_TAIL"
        require(completed["copied"] == [expected], "Stop did not copy exactly once")
        require(completed["completed"] == [expected], "Completion did not run exactly once")
        require(completed["pasteTarget"] == expected, "AppKit paste target did not receive clipboard text")
        require(completed["latestRecording"]["transcript"] == expected, "Transcript was not persisted")
        require(not completed["overlay"]["visible"], "Overlay remained open after Stop")
        return {"copied": expected, "saved": completed["latestRecording"]["id"], "requestCount": completed["requestCount"]}

    def cancelled_reply():
        client.command("fake", behavior="hold")
        start()
        client.command("inject", committed="Old sentence.", partial="old tail")
        client.wait(requestCount=1)
        client.command("cancel")
        cancelled = client.wait(phase="idle")
        require(cancelled["copied"] == ["Old sentence. old tail"], "Cancel did not copy visible text")
        require(cancelled["recordingCount"] == 0, "Cancelled recording entered history")
        client.command("fake", behavior="success")
        start()
        client.command("inject", committed="New sentence.")
        client.command("releaseRequests")
        completed = stop()
        require(completed["completed"] == ["NEW_SENTENCE"], "A cancelled reply completed or changed the new session")
        require(completed["pasteTarget"] == "NEW_SENTENCE", "Stale text reached the paste target")
        return {"copies": completed["copied"], "completed": completed["completed"]}

    def preparing_cancel():
        client.command("inputFaults", holdPreparation=True)
        client.command("start")
        prepared = client.wait(phase="preparing")
        require(prepared["overlay"]["visible"], "Preparing overlay missing")
        client.command("cancel")
        client.wait(phase="idle")
        client.command("inputFaults")
        state = start()
        require(state["phase"] == "listening", "Restart after cancelled preparation failed")
        client.command("cancel")
        client.wait(phase="idle")
        return {"restart": "listening"}

    def fake_failure(behavior):
        client.command("fake", behavior=behavior)
        start()
        client.command("inject", committed="A complete sentence.")
        failed = client.wait(phase="failed")
        require(not failed["completed"], "Failure completed/pasted a partial transcript")
        require(not failed["pasteTarget"], "Failure pasted text")
        require(failed["recordingCount"] == 1, "Failure lost captured audio")
        require(failed["latestRecording"].get("transcriptionError"), "Failure was not saved in recording history")
        require(failed["overlay"]["status"].startswith("Error:"), "Failure not visible in the real overlay")
        return {"failure": failed["failure"], "saved": failed["latestRecording"]["id"]}

    def input_failure(stage):
        if stage == "start":
            client.command("inputFaults", failStart=True)
            client.command("start")
        else:
            start()
            client.command("inject", committed="Preserve this recording.")
            if stage == "stream": client.command("inputFailure")
            elif stage == "stop":
                client.command("inputFaults", failStop=True)
                client.command("stop")
            elif stage == "cancel":
                client.command("inputFaults", failCancel=True)
                client.command("cancel")
        failed = client.wait(phase="failed")
        require(not failed["completed"], "Input failure completed a transcript")
        require(failed["overlay"]["visible"] and failed["overlay"]["status"].startswith("Error:"), "Input failure was not visible in the actual overlay")
        require(failed["recordingCount"] == (0 if stage == "start" else 1), "Input failure history is incorrect")
        return {"failure": failed["failure"], "recordings": failed["recordingCount"]}

    def settings_payload():
        client.command("settings", prompt="Keep the original tone.", dictionary="jason = JSON\nopen ai = OpenAI", contextLines="5")
        start()
        client.command("inject", committed="Use jason with open ai.")
        state = stop()
        page = client.request("/requests")
        receipt = client.request("/requests/" + page["requests"][0]["id"])
        require("Keep the original tone." in receipt["instructions"], "Custom cleanup prompt not posted")
        require('"jason" : "JSON"' in receipt["instructions"], "Dictionary not posted as JSON")
        require(state["settings"]["contextLines"] == 5, "Context line setting not applied")
        try:
            client.command("settings", prompt="", dictionary="bad entry", contextLines="0")
            raise AssertionError("Invalid settings were accepted")
        except RuntimeError:
            pass
        require(client.state()["settings"] == state["settings"], "Rejected settings changed configuration")
        import urllib.request
        import urllib.error
        try:
            urllib.request.urlopen(urllib.request.Request(client.url + "/state", headers={"X-Chatty-Debug-Token": "wrong-token"}), timeout=5)
            raise AssertionError("Control endpoint accepted a wrong token")
        except urllib.error.HTTPError as error:
            require(error.code == 401, "Wrong token did not return HTTP 401")
        for path, payload in [("/command", {"action": "unknown"}), ("/command", {"action": "level", "level": 2}), ("/requests?limit=101", None)]:
            try:
                client.request(path, payload)
                raise AssertionError("Invalid boundary input was accepted")
            except RuntimeError:
                pass
        return {"model": receipt["model"], "contextLines": 5, "settingsPersisted": True}

    def long_overlay():
        client.command("fake", behavior="hold")
        start()
        text = " ".join(["A longer sentence with café and Unicode 🚀."] * 45)
        client.command("inject", committed=text, partial="The latest provisional words")
        state = client.wait(requestCount=1)
        overlay = state["overlay"]
        require(overlay["text"] == text + " The latest provisional words", "The UI lost or truncated transcript text")
        require(overlay["documentHeight"] > overlay["viewportHeight"], "Long transcript did not overflow its viewport")
        require(abs(overlay["scrollY"] - (overlay["documentHeight"] - overlay["viewportHeight"])) < 2, "Viewport did not scroll to newest text")
        require(overlay["height"] < 400, "Overlay did not stop growing at five lines")
        client.command("cancel")
        client.wait(phase="idle")
        client.command("releaseRequests")
        return {"characters": len(overlay["text"]), "height": overlay["height"], "scrollY": overlay["scrollY"]}

    def saved_fixture():
        start()
        client.command("inject", committed="Original saved transcript.")
        return stop()["latestRecording"]["id"]

    def history_recovery():
        recording_id = saved_fixture()
        client.command("vocabulary", value="Swift and AppKit")
        client.command("fake", behavior="rateLimited")
        client.command("transcribeRecording", recordingID=recording_id)
        failed = client.wait(historyID=recording_id, historyPhase="failed")
        require(failed["latestRecording"].get("transcriptionError"), "Upload failure was not saved")
        require(failed["overlay"]["canRetry"], "Failed upload did not expose Retry")
        client.command("clearRecordingError", recordingID=recording_id)
        require(not client.state()["latestRecording"].get("transcriptionError"), "Clear error did not persist")
        client.command("fake", behavior="success", audioText="Recovered saved recording.")
        client.command("retryTranscription", recordingID=recording_id)
        completed = client.wait(historyID=recording_id, historyPhase="complete")
        require(completed["latestRecording"]["transcript"] == "RECOVERED_SAVED_RECORDING", "Retry did not save new transcript")
        latest_request = client.request("/requests")["requests"][-1]["id"]
        require(client.request("/requests/" + latest_request)["prompt"] == "Swift and AppKit", "Saved vocabulary was not posted with audio")
        require(completed["copied"][-1] == "RECOVERED_SAVED_RECORDING", "Retry did not copy")
        require(not completed["latestRecording"].get("transcriptionError"), "Retry retained old error")
        client.command("copyRecording", recordingID=recording_id)
        require(client.state()["copied"][-2:] == ["RECOVERED_SAVED_RECORDING"] * 2, "History Copy did not use saved transcript")
        return {"recording": recording_id, "retry": "complete"}

    def history_cancel_and_overlap():
        recording_id = saved_fixture()
        client.command("fake", behavior="hold", audioText="Stale saved words.")
        before = client.state()["requestCount"]
        client.command("transcribeRecording", recordingID=recording_id)
        client.wait(requestCount=before + 1)
        client.command("cancelTranscription", recordingID=recording_id)
        client.wait(historyID=recording_id, historyPhase="cancelled")
        client.command("fake", behavior="hold", audioText="Background saved words.")
        client.command("retryTranscription", recordingID=recording_id)
        client.wait(requestCount=before + 2)
        start()
        client.command("inject", partial="New live dictation")
        client.wait(textContains="New live dictation")
        client.command("releaseRequests")
        state = client.wait(historyID=recording_id, historyPhase="complete")
        require(state["overlay"]["text"] == "New live dictation", "Background upload overwrote the live overlay")
        require(state["overlay"]["visible"], "Background upload closed live dictation")
        require(state["copied"] == ["ORIGINAL_SAVED_TRANSCRIPT"], "Background reply stole clipboard ownership")
        client.command("fake", behavior="success")
        finished = stop()
        require(finished["pasteTarget"].endswith("NEW_LIVE_DICTATION"), "Live session did not finish after background upload")
        return {"lateReplyRejected": True, "backgroundPersisted": True, "liveCompleted": True}

    def actual_settings_window():
        def edit(label, value):
            client.command("ui", view="settings", control=label, value=value)
        def click(label):
            client.command("ui", view="settings", control=label, click=True)
        def fields():
            return {e["label"]: e.get("value") for e in client.request("/ui/settings")["controls"]}
        original = client.state()["settings"]
        client.command("ui", view="settings", show=True)
        edit("Context lines", "0")
        click("Save")
        require(client.request("/ui/settings")["visible"], "Invalid settings closed the window")
        require(fields()["Settings validation"], "Validation failure was not visible")
        require(client.state()["settings"] == original, "Invalid settings were persisted")
        edit("Cleanup instructions", "Preserve my wording.")
        edit("Word dictionary", "jason = JSON")
        edit("Context lines", "4")
        click("Save")
        require(not client.request("/ui/settings")["visible"], "Save did not close settings")
        require(client.state()["settings"]["contextLines"] == 4, "Save action did not apply settings")
        client.command("ui", view="settings", show=True)
        edit("Cleanup instructions", "Discard this edit")
        click("Cancel")
        require(client.state()["settings"]["prompt"] == "Preserve my wording.", "Cancel persisted edited settings")
        client.command("ui", view="settings", show=True)
        click("Reset to Defaults")
        require(fields()["Context lines"] == "3", "Reset did not reset the form")
        require(client.state()["settings"]["contextLines"] == 4, "Reset persisted before Save")
        click("Save")
        require(client.state()["settings"]["contextLines"] == 3, "Saving reset defaults failed")
        return {"save": True, "validation": True, "cancel": True, "resetThenSave": True}

    def actual_panel_actions():
        client.command("ui", view="panel", control="Dictation text", value="Panel injected sentence.")
        client.command("ui", view="panel", control="Injected provisional text", value="panel live tail")
        client.command("ui", view="panel", control="Start dictation", click=True)
        client.wait(phase="listening")
        client.command("ui", view="panel", control="Inject snapshot", click=True)
        client.wait(textContains="panel live tail")
        client.command("ui", view="panel", control="Stop dictation", click=True)
        state = client.wait(phase="complete")
        require(state["copied"] == ["PANEL_INJECTED_SENTENCE_PANEL_LIVE_TAIL"], "Panel actions did not drive real dictation")
        client.command("fake", behavior="success", audioText="Panel history result.")
        client.command("ui", view="panel", control="Transcribe / Retry", click=True)
        state = client.wait(historyID=state["latestRecording"]["id"], historyPhase="complete")
        require(state["latestRecording"]["transcript"] == "PANEL_HISTORY_RESULT", "History panel action did not upload")
        return {"dictationButtons": True, "historyUploadButton": True}

    def native_shortcut_dispatch():
        client.command("ui", view="shortcut", show=True)
        client.command("shortcutKey", keyCode=0, value="a")
        capture = client.request("/ui/shortcut")
        require(capture["visible"], "An unmodified letter committed a global shortcut")
        client.command("shortcutKey", keyCode=53)
        require(client.state()["platform"]["shortcut"] == "Double Left Shift", "Escape changed the binding")
        client.command("ui", view="shortcut", show=True)
        client.command("shortcutKey", keyCode=80, value="F19", modifiers=["command", "control", "option"])
        require("F19" in client.state()["platform"]["shortcut"], "Captured shortcut was not applied")
        client.command("globals", enabled=True)
        require(client.state()["platform"]["recordingHotkey"] == "true", "Carbon failed to register the shortcut")
        client.command("nativeHotkey", keyCode=2)
        listening = client.wait(phase="listening")
        require(listening["platform"]["escapeHotkey"] == "true", "Escape was not registered while active")
        client.command("inject", partial="Escape through Carbon")
        client.wait(textContains="Escape through Carbon")
        client.command("nativeHotkey", keyCode=1)
        cancelled = client.wait(phase="idle")
        require(cancelled["copied"] == ["Escape through Carbon"], "Native Escape handler did not copy and cancel")
        require(cancelled["platform"]["escapeHotkey"] == "false", "Escape registration leaked after cancel")
        client.command("globals", enabled=False)
        require(client.state()["platform"]["recordingHotkey"] == "false", "Recording hotkey was not unregistered")
        client.command("resetShortcut")
        return {"capture": True, "invalidKey": True, "cancelCapture": True, "carbonRegistrationAndDispatch": True}

    def persistence_failure():
        from urllib.parse import urlparse, unquote
        directory = Path(unquote(urlparse(client.state()["directory"]).path))
        metadata = directory / "recordings.json"
        audio_before = set((directory / "Recordings").glob("*.m4a"))
        start()
        client.command("inject", committed="Keep this audio safe.")
        client.wait(corrected="KEEP_THIS_AUDIO_SAFE")
        metadata.write_text("deliberately corrupt metadata")
        try:
            client.command("stop")
            failed = client.wait(phase="failed")
            require(failed.get("storageError"), "Corrupt history was silently ignored")
            require("Could not save recording history" in failed["failure"], "Persistence failure was not explained")
            require(not failed["completed"], "Failed persistence completed/pasted")
            preserved = set((directory / "Recordings").glob("*.m4a")) - audio_before
            require(len(preserved) == 1 and next(iter(preserved)).stat().st_size > 1000, "Persistence failure lost the AAC recording")
        finally:
            # Repair only the deliberately corrupted, initially empty sandbox.
            metadata.write_text("[]")
            for file in set((directory / "Recordings").glob("*.m4a")) - audio_before: file.unlink()
        start()
        client.command("inject", committed="Recovery after repairing storage.")
        completed = stop()
        require(completed["recordingCount"] == 1, "Controller could not recover after storage repair")
        connection = next(e["value"] for e in client.request("/ui/panel")["controls"] if e["label"] == "Harness connection")
        require(connection.startswith("Isolated data:"), "Panel kept a stale storage error after repair")
        return {"visibleFailure": True, "audioPreserved": True, "restartAfterRepair": True}

    def speech_settings():
        require(client.state()["speechEngine"] == "apple", "Fresh settings did not default to Apple")
        client.command("ui", view="speech", show=True)
        client.command("ui", view="speech", control="Speech recognition engine", value="Nemotron 600M · local streaming")
        client.command("ui", view="speech", control="Cancel", click=True)
        require(client.state()["speechEngine"] == "apple", "Cancel changed the recognizer")
        client.command("ui", view="speech", show=True)
        if client.state()["model"]["phase"] == "notDownloaded":
            client.command("ui", view="speech", control="Speech recognition engine", value="Nemotron 600M · local streaming")
            client.command("ui", view="speech", control="Save", click=True)
            require(client.request("/ui/speech")["visible"], "Missing model was accepted without download")
        phase = client.state()["model"]["phase"]
        if phase not in ["ready", "preparing"]:
            client.command("ui", view="speech", control="Download local model", click=True)
        if phase != "ready":
            client.wait(modelPhase="ready", timeoutSeconds=900)
        client.command("ui", view="speech", control="Speech recognition engine", value="Nemotron 600M · local streaming")
        client.command("ui", view="speech", control="Save", click=True)
        require(client.state()["speechEngine"] == "nemotron", "Save did not switch the configured recognizer")
        client.command("ui", view="speech", show=True)
        form = client.request("/ui/speech")
        selected = next(e["value"] for e in form["controls"] if e["label"] == "Speech recognition engine")
        require(selected == "Nemotron 600M · local streaming", "Settings did not reload saved choice")
        client.command("ui", view="speech", control="Cancel", click=True)
        from urllib.parse import urlparse, unquote
        config = json.loads((Path(unquote(urlparse(client.state()["directory"]).path)) / "config.json").read_text())
        require(config["speechRecognition"] == "nemotron", "Recognizer choice was not persisted to disk")
        return {"appleDefault": True, "cancel": True, "loadActualModel": True, "savedAndReloaded": True}

    run("stream-queue-stop-persist-paste", held_cleanup)
    run("cancel-late-reply-restart", cancelled_reply)
    run("cancel-preparation-restart", preparing_cancel)
    for behavior in ["unauthorized", "rateLimited", "serverError", "malformed", "empty", "refused", "incomplete", "disconnect"]:
        run("http-" + behavior, lambda behavior=behavior: fake_failure(behavior))
    for stage in ["start", "stream", "stop", "cancel"]:
        run("input-" + stage, lambda stage=stage: input_failure(stage))
    run("saved-recording-failure-retry-clear-copy", history_recovery)
    run("saved-recording-cancel-retry-overlapping-dictation", history_cancel_and_overlap)
    run("actual-settings-save-validation-cancel-reset", actual_settings_window)
    run("actual-debug-panel-buttons", actual_panel_actions)
    run("native-shortcut-capture-registration-dispatch", native_shortcut_dispatch)
    run("settings-to-posted-payload", settings_payload)
    run("long-unicode-overlay", long_overlay)
    run("persistence-corruption-audio-preservation-repair", persistence_failure)
    if with_audio:
        run("production-speech-settings-default-download-save-cancel", speech_settings)
        def audio_pipeline():
            fixture = Path(__file__).resolve().parent.parent / "Tests/Fixtures/statements-with-pauses.wav"
            client.command("replayAudio", audioPath=str(fixture))
            client.wait(phase="listening")
            completed = client.wait(phase="complete")
            expected = "THIS_IS_A_STATEMENT_WITHOUT_A_QUESTION_NOW_I_AM_STARTING_ANOTHER_TOPIC"
            require(completed["recognitionEngine"] == "nemotron", "Replay did not use the configured local recognizer")
            require(completed["completed"] == [expected], "Audio words were lost or changed across the pause")
            require(completed["pasteTarget"] == expected, "Recognized audio did not reach the paste target")
            require(completed["recordingCount"] == 1, "Replayed audio was not saved through the real recording path")
            require(completed["requestCount"] >= 2, "Pause endpoint did not submit both sentences during recording")
            return {"transcript": expected, "saved": completed["latestRecording"]["id"]}
        run("real-audio-capture-recognition-cleanup-persistence", audio_pipeline)

        def audio_cancel_restart():
            fixture = Path(__file__).resolve().parent.parent / "Tests/Fixtures/statements-with-pauses.wav"
            client.command("replayAudio", audioPath=str(fixture))
            client.wait(phase="listening")
            client.wait(textContains="statement")
            client.command("cancel")
            cancelled = client.wait(phase="idle")
            require(cancelled["recordingCount"] == 0, "Cancelled audio replay was saved")
            client.command("reset", clearData=True)
            client.command("replayAudio", audioPath=str(fixture))
            client.wait(phase="listening")
            client.wait(textContains="statement")
            completed = stop()
            require(completed["recordingCount"] == 1 and completed["completed"], "Early Stop did not flush/save recognized speech")
            require("ANOTHER_TOPIC" not in completed["completed"][0], "Cancelled/unstopped source leaked later audio")
            return {"cancelJoined": True, "restart": True, "earlyStopFlushed": True}
        run("real-audio-cancel-restart-early-stop", audio_cancel_restart)

        def silent_audio():
            import wave
            from urllib.parse import urlparse, unquote
            directory = Path(unquote(urlparse(client.state()["directory"]).path))
            fixture = directory / "silence.wav"
            with wave.open(str(fixture), "wb") as audio:
                audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(16000)
                audio.writeframes(bytes(16000 * 2 * 2))
            client.command("replayAudio", audioPath=str(fixture))
            failed = client.wait(phase="failed")
            require("No speech" in failed["failure"], "Silent audio was hallucinated or accepted")
            require(failed["recordingCount"] == 1 and not failed["completed"], "Silence failure lost audio or pasted text")
            fixture.unlink()
            return {"noHallucination": True, "errorVisible": True, "audioSaved": True}
        run("real-silent-audio-no-speech", silent_audio)

        def missing_audio():
            client.command("replayAudio", audioPath="/nonexistent/chatty-audio-test.wav")
            failed = client.wait(phase="failed")
            require(failed["recordingCount"] == 0 and not failed["completed"], "Missing source created a recording or pasted")
            return {"failure": failed["failure"]}
        run("real-audio-source-failure", missing_audio)
        def apple_switch_replay():
            fixture = Path(__file__).resolve().parent.parent / "Tests/Fixtures/statements-with-pauses.wav"
            client.command("replayAudio", audioPath=str(fixture))
            client.wait(phase="listening")
            client.command("ui", view="speech", show=True)
            client.command("ui", view="speech", control="Speech recognition engine", value="Apple · built in")
            client.command("ui", view="speech", control="Save", click=True)
            previous = client.wait(phase="complete")
            require(previous["recognitionEngine"] == "nemotron", "Changing settings replaced an active recognition session")
            require(previous["speechEngine"] == "apple", "Settings did not save the next session's engine")
            client.command("reset", clearData=True)
            client.command("replayAudio", audioPath=str(fixture))
            completed = client.wait(phase="complete")
            require(completed["recognitionEngine"] == "apple", "Switch did not select the production Apple recognizer")
            require("STATEMENT_WITHOUT_A_QUESTION" in completed["completed"][0], "Apple recognition lost the fixture's first statement")
            require("STARTING_ANOTHER_TOPIC" in completed["completed"][0], "Apple recognition lost the continuation")
            require(completed["latestRecording"]["transcript"] == completed["completed"][0], "Apple output did not persist")
            require(completed["pasteTarget"] == completed["completed"][0], "Apple output did not reach the paste destination")
            return {"engine": "apple", "completed": completed["completed"][0], "persistedAndPasted": True}
        run("switch-back-to-production-apple-replay-save-paste", apple_switch_replay)
    client.command("reset", clearData=True)
    return {"passed": all(result["passed"] for result in results), "scenarios": results}


def launch_and_verify(root, with_audio, report_path, cold_model=False, model_cache=None):
    workspace = Path(tempfile.mkdtemp(prefix="verification-", dir=root / "build"))
    bundle = workspace / "Chatty Verification.app"
    subprocess.run([str(root / "scripts/package-debug.sh"), str(bundle), "local.chatty.Chatty.verification"], check=True)
    control = workspace / "control.json"
    environment = {**os.environ, "CHATTY_DEBUG_DIRECTORY": str(workspace / "data"), "CHATTY_DEBUG_CONTROL_FILE": str(control)}
    if cold_model: environment["CHATTY_DEBUG_MODEL_DIRECTORY"] = str(workspace / "data/Models")
    if model_cache: environment["CHATTY_DEBUG_MODEL_DIRECTORY"] = str(model_cache.resolve())
    log_path = workspace / "app.log"
    app = subprocess.Popen([str(bundle / "Contents/MacOS/Chatty")], env=environment,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    client = None
    try:
        with log_path.open("wb") as log, selectors.DefaultSelector() as selector:
            selector.register(app.stdout, selectors.EVENT_READ)
            deadline = time.monotonic() + 40
            data = b""
            while b"CHATTY_HARNESS_READY " not in data:
                events = selector.select(max(0, deadline - time.monotonic()))
                if not events: raise RuntimeError(f"App startup timed out; see {log_path}")
                chunk = os.read(app.stdout.fileno(), 65536)
                if not chunk: raise RuntimeError(f"App exited before readiness; see {log_path}")
                log.write(chunk); log.flush(); data += chunk
        client = module.HarnessClient(control)
        report = verify(client, with_audio)
        # Capture a representative own-view artifact after exercising real controls.
        client.command("ui", view="panel", control="Dictation text", value="Ready for another test.")
        report["artifacts"] = [client.command("render", view="panel")["artifact"]]
        client.command("fake", behavior="hold")
        client.command("start"); client.wait(phase="listening")
        client.command("inject", committed="The active sentence.", partial="The latest live words")
        client.wait(requestCount=1)
        report["artifacts"].append(client.command("render", view="overlay")["artifact"])
        client.command("reset", clearData=True)
        report["workspace"] = str(workspace)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        client.command("quit")
        app.wait(timeout=10)
        require(app.returncode == 0, "App did not quit cleanly")
        return report
    finally:
        if app.poll() is None:
            app.terminate()
            try: app.wait(timeout=10)
            except subprocess.TimeoutExpired: app.kill(); app.wait()
        app.stdout.close()


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control", type=Path, default=root / "build/debug-control.json")
    parser.add_argument("--report", type=Path, default=root / "build/debug-verification.json")
    parser.add_argument("--audio", action="store_true", help="Also exercise the downloaded local model and real audio/recording pipeline")
    parser.add_argument("--model-cache", type=Path, help="Use a specific model cache for download/resume checks")
    parser.add_argument("--cold-model", action="store_true", help="Use a fresh model cache and download through the actual settings workflow; use with --launch --audio")
    parser.add_argument("--launch", action="store_true", help="Package an already-built debug binary, launch a unique sandbox, verify and quit only that app")
    args = parser.parse_args()
    try:
        report = launch_and_verify(root, args.audio, args.report, args.cold_model, args.model_cache) if args.launch else verify(module.HarnessClient(args.control), with_audio=args.audio)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(json.dumps({"passed": report["passed"], "scenarios": len(report["scenarios"]), "failures": [r["name"] for r in report["scenarios"] if not r["passed"]], "report": str(args.report)}))
        sys.exit(0 if report["passed"] else 1)
    except Exception as error:
        print(json.dumps({"error": str(error)}), file=sys.stderr)
        sys.exit(1)
