#!/usr/bin/env python3
"""Drive the running debug app through its authenticated loopback control API."""
import argparse
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request


class HarnessClient:
    def __init__(self, control_file):
        self.connection = json.loads(Path(control_file).read_text())
        os.kill(self.connection["pid"], 0)
        self.url = self.connection["url"].rstrip("/")

    def request(self, path, payload=None, timeout=20):
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(self.url + path, data=data, headers={
            "X-Chatty-Debug-Token": self.connection["token"],
            "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode()
            raise RuntimeError(f"HTTP {error.code}: {detail}") from error

    def command(self, action, **values):
        return self.request("/command", {"action": action, **values})

    def state(self):
        return self.request("/state")

    def wait(self, **condition):
        return self.request("/wait", condition, timeout=max(20, condition.get("timeoutSeconds", 15) + 5))


def parser():
    root = Path(__file__).resolve().parent.parent
    p = argparse.ArgumentParser(description=__doc__, epilog="Start with ./scripts/run-debug.sh. Commands emit JSON; failures exit nonzero. Mutations acknowledge acceptance; use wait to verify completion. The local fake needs no OpenAI key.")
    p.add_argument("--control", type=Path, default=root / "build/debug-control.json", help="Connection file written by the running debug app (contains a local control token)")
    commands = p.add_subparsers(dest="action", required=True)
    commands.add_parser("state", help="Full controller, overlay, clipboard, paste and storage snapshot")
    commands.add_parser("schema", help="Show the command and wait-condition schemas")
    for name in ["start", "stop", "cancel", "toggle", "release", "release-preparation", "input-failure", "paste-target", "restore-clipboard", "quit"]:
        commands.add_parser(name)
    system_paste = commands.add_parser("system-paste", help="Arm a one-shot production keyboard paste into an external test application")
    system_paste.add_argument("--target-bundle", help="Running test app bundle ID; defaults to the frontmost app")
    inject = commands.add_parser("inject", help="Inject a complete recognition snapshot through the real input stream")
    inject.add_argument("--committed", default="")
    inject.add_argument("--partial", default="")
    meter = commands.add_parser("meter", help="Drive waveform and recording-size UI")
    meter.add_argument("--level", type=float, required=True)
    meter.add_argument("--bytes", type=int, default=0)
    fake = commands.add_parser("fake", help="Select the next HTTP reply; hold waits for release")
    fake.add_argument("behavior", choices=["success", "hold", "unauthorized", "rateLimited", "serverError", "malformed", "empty", "refused", "incomplete", "disconnect"])
    fake.add_argument("--audio-text", help="Reference transcript returned for uploaded audio")
    replay = commands.add_parser("replay", help="Replay audio through the real resampler, AAC recorder and local recognizer")
    replay.add_argument("file", type=Path)
    render = commands.add_parser("render", help="Render the app's own view tree to a PNG artifact")
    render.add_argument("view", choices=["panel", "overlay", "settings", "paste", "shortcut", "speech"])
    globals_command = commands.add_parser("globals", help="Explicitly enable or disable native global shortcuts")
    globals_command.add_argument("--enabled", action=argparse.BooleanOptionalAction, default=False)
    faults = commands.add_parser("faults", help="Configure injected input failures; unspecified faults are cleared")
    for flag in ["hold-preparation", "fail-start", "fail-stop", "fail-cancel"]:
        faults.add_argument("--" + flag, action="store_true")
    wait = commands.add_parser("wait", help="Wait for observed state changes, with a 15-second deadline")
    wait.add_argument("--timeout", dest="timeoutSeconds", type=int)
    wait.add_argument("--model-phase", dest="modelPhase", choices=["notDownloaded", "downloaded", "preparing", "ready", "failed"])
    wait.add_argument("--history-id", dest="historyID")
    wait.add_argument("--history-phase", dest="historyPhase", choices=["transcribing", "complete", "cancelled", "failed"])
    wait.add_argument("--phase", choices=["idle", "preparing", "listening", "finishing", "complete", "failed"])
    wait.add_argument("--contains", dest="textContains")
    wait.add_argument("--corrected")
    wait.add_argument("--requests", dest="requestCount", type=int)
    wait.add_argument("--recordings", dest="recordingCount", type=int)
    ui = commands.add_parser("ui", help="Inspect or operate actual AppKit controls by their Accessibility labels")
    ui.add_argument("view", choices=["panel", "settings", "paste", "shortcut", "speech"])
    ui.add_argument("--show", action="store_true")
    ui.add_argument("--control-label")
    ui.add_argument("--value")
    ui.add_argument("--click", action="store_true")
    history = commands.add_parser("history", help="Drive saved-recording upload, retry, cancellation and copy through the real controller")
    history.add_argument("operation", choices=["transcribe", "cancel", "retry", "copy", "clear-error"])
    history.add_argument("id")
    history.add_argument("--paste", action="store_true")
    requests = commands.add_parser("requests", help="Bounded request summaries; --id expands one posted payload")
    requests.add_argument("--limit", type=int, default=20)
    requests.add_argument("--offset", type=int, default=0)
    requests.add_argument("--id")
    settings = commands.add_parser("settings", help="Parse and save cleanup settings through ConfigStore")
    settings.add_argument("--prompt", required=True)
    settings.add_argument("--dictionary", default="", help="Newline-separated recognized = preferred mappings")
    settings.add_argument("--context-lines", default="3")
    reset = commands.add_parser("reset", help="Cancel input and restore injected input/local fake; production data is untouched")
    reset.add_argument("--clear-data", action="store_true", help="Also remove recordings in this debug workspace")
    raw = commands.add_parser("command", help="Send a typed JSON command; see schema")
    raw.add_argument("json")
    return p


def run(args):
    if args.action == "schema":
        return {
            "command": {
                "action": "start|stop|cancel|toggle|inject|level|inputFailure|inputFaults|releasePreparation|fake|releaseRequests|settings|vocabulary|reset|showPasteTarget|clearPasteTarget|globals|replayAudio|render|ui|transcribeRecording|cancelTranscription|retryTranscription|copyRecording|clearRecordingError|shortcutKey|resetShortcut|nativeHotkey|systemPaste|restoreClipboard|quit",
                "inject": {"committed": "text", "partial": "text"},
                "level": {"level": "0...1", "bytes": "nonnegative integer"},
                "inputFaults": {"holdPreparation": False, "failStart": False, "failStop": False, "failCancel": False},
                "fake": {"behavior": "success|hold|unauthorized|rateLimited|serverError|malformed|empty|refused|incomplete|disconnect", "audioText": "reference text for audio uploads"},
                "settings": {"prompt": "instructions", "dictionary": "recognized = preferred\n...", "contextLines": "positive integer string"},
                "vocabulary": {"value": "optional saved-audio vocabulary"},
                "globals": {"enabled": False},
                "replayAudio": {"audioPath": "absolute file path"},
                "render": {"view": "panel|overlay|settings|paste|shortcut|speech"},
                "ui": {"view": "panel|settings|paste|shortcut|speech", "show": True, "control": "Accessibility label or button title", "value": "optional edit", "click": False},
                "historyActions": {"recordingID": "UUID from state.latestRecording", "paste": False},
                "shortcutKey": {"keyCode": "macOS UInt16 code", "modifiers": ["command", "control", "option", "shift"], "value": "characters"},
                "nativeHotkey": {"keyCode": "1 for Escape or 2 for recording; requires globals enabled"},
                "reset": {"clearData": False},
            },
            "wait": {"phase": "idle|preparing|listening|finishing|complete|failed", "textContains": "text", "corrected": "EXACT_TEXT", "requestCount": 1, "recordingCount": 1, "historyID": "UUID", "historyPhase": "transcribing|complete|cancelled|failed"},
            "requests": "Summaries default to 20, maximum 100. Use --id to inspect one full payload.",
            "ui": "GET /ui/panel, /ui/settings, /ui/paste or /ui/shortcut returns the real control tree.",
        }
    client = HarnessClient(args.control)
    if args.action == "state": return client.state()
    if args.action == "command": return client.request("/command", json.loads(args.json))
    if args.action == "system-paste": return client.command("systemPaste", value=args.target_bundle)
    if args.action == "inject": return client.command("inject", committed=args.committed, partial=args.partial)
    if args.action == "meter": return client.command("level", level=args.level, bytes=args.bytes)
    if args.action == "fake": return client.command("fake", behavior=args.behavior, audioText=args.audio_text)
    if args.action == "replay": return client.command("replayAudio", audioPath=str(args.file.resolve()))
    if args.action == "render": return client.command("render", view=args.view)
    if args.action == "globals": return client.command("globals", enabled=args.enabled)
    if args.action == "faults":
        return client.command("inputFaults", holdPreparation=args.hold_preparation, failStart=args.fail_start, failStop=args.fail_stop, failCancel=args.fail_cancel)
    if args.action == "wait":
        return client.wait(**{k: getattr(args, k) for k in ["phase", "textContains", "corrected", "requestCount", "recordingCount", "historyID", "historyPhase", "modelPhase", "timeoutSeconds"] if getattr(args, k) is not None})
    if args.action == "ui":
        if args.show or args.control_label:
            client.command("ui", view=args.view, show=args.show, control=args.control_label, value=args.value, click=args.click)
        return client.request("/ui/" + args.view)
    if args.action == "history":
        action = {"transcribe": "transcribeRecording", "cancel": "cancelTranscription", "retry": "retryTranscription", "copy": "copyRecording", "clear-error": "clearRecordingError"}[args.operation]
        return client.command(action, recordingID=args.id, paste=args.paste)
    if args.action == "requests":
        return client.request("/requests/" + urllib.parse.quote(args.id) if args.id else f"/requests?limit={args.limit}&offset={args.offset}")
    if args.action == "settings": return client.command("settings", prompt=args.prompt, dictionary=args.dictionary, contextLines=args.context_lines)
    if args.action == "reset": return client.command("reset", clearData=args.clear_data)
    action = {"release": "releaseRequests", "release-preparation": "releasePreparation", "input-failure": "inputFailure", "paste-target": "showPasteTarget", "system-paste": "systemPaste", "restore-clipboard": "restoreClipboard"}.get(args.action, args.action)
    return client.command(action)


if __name__ == "__main__":
    try:
        print(json.dumps(run(parser().parse_args()), ensure_ascii=False, indent=2))
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        print(json.dumps({"error": {"type": type(error).__name__, "message": str(error)}}), file=sys.stderr)
        sys.exit(1)
