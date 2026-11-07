import ChattyHarness
import Darwin
import Foundation

@main
@MainActor
struct ChattyDebugCLI {
    static let help = """
    Usage: chatty-debug [--control /absolute/control.json] <command> [options]

    Drive the running debug app. JSON goes to stdout; errors to stderr/nonzero.
    Start scripts/run-debug.sh first. Commands acknowledge acceptance; wait for
    observed completion. The default loopback fake needs no OpenAI token.

      state                        Controller, overlay, storage and paste snapshot
      start | stop | cancel | toggle | quit
      inject --committed TEXT [--partial TEXT]
      meter --level 0...1 [--bytes N]
      fake success|hold|unauthorized|rateLimited|serverError|malformed|empty|refused|incomplete|disconnect
           [--audio-text TEXT]
      release | release-preparation | input-failure
      faults [--hold-preparation] [--fail-start] [--fail-stop] [--fail-cancel]
      replay FILE                  Inject a clock-paced audio source
      wait [--phase PHASE] [--contains TEXT] [--corrected TEXT] [--requests N]
           [--recordings N] [--history-id UUID] [--history-phase PHASE]
           [--model-phase PHASE] [--paste-dispatches N] [--timeout SECONDS]
      ui panel|speech|settings|paste|shortcut [--show]
      render panel|overlay|speech|settings|paste|shortcut
      history transcribe|cancel|retry|copy|clear-error UUID [--paste]
      requests [--limit N] [--offset N] [--id ID]   Default 20 summaries, max 100
      settings --prompt TEXT [--dictionary TEXT] [--context-lines N]
      globals --enabled | --no-enabled
      system-paste [--target-bundle ID] | restore-clipboard | paste-target
      reset [--clear-data]          Clears only indexed debug recordings
      command JSON                 Full typed app command, including UI/fault setup
      command --file FILE          Read a JSON command without shell escaping
      schema                       Command/wait shape and expansion guidance

    UI workflow acceptance is scripts/test-ui.sh (XCUITest), not this CLI.
    """

    static func main() async {
        do { try emit(await run(Array(CommandLine.arguments.dropFirst()))) }
        catch {
            let payload: [String: Any] = ["error": ["message": error.localizedDescription]]
            let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            FileHandle.standardError.write(data + Data([10])); exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws -> Data {
        var args = arguments
        var control = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/debug-control.json")
        if args.first == "--control" {
            guard args.count >= 3 else { throw HarnessError("--control requires a file and command") }
            control = URL(fileURLWithPath: args[1]); args.removeFirst(2)
        }
        guard let action = args.first else { print(help); return Data() }
        if ["--help", "-h", "help"].contains(action) { print(help); return Data() }
        if action == "schema" {
            return try JSONSerialization.data(withJSONObject: [
                "command": ["action": "App command name; see --help", "fields": "Typed by DebugHarness.Command; invalid actions/values return HTTP 400"],
                "wait": ["phase": "idle|preparing|listening|finishing|complete|failed", "textContains": "substring", "corrected": "exact text", "requestCount": 1, "recordingCount": 1, "historyID": "UUID", "historyPhase": "transcribing|complete|cancelled|failed", "modelPhase": "notDownloaded|downloaded|preparing|ready|failed", "timeoutSeconds": 15, "systemPasteDispatches": 1],
                "requests": "At most 20 summaries by default (maximum 100); --id expands one actual payload.",
                "rawExample": ["action": "ui", "view": "speech", "show": true]
            ], options: [.sortedKeys])
        }
        let client = try HarnessClient(controlFile: control)
        let parsed = try Options(Array(args.dropFirst()))
        func value(_ name: String) throws -> String { try parsed.required(name) }
        switch action {
        case "state": return try await client.request("/state")
        case "command":
            let data = try parsed.values["file"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
                ?? Data((try parsed.argument(0)).utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HarnessError("Command must be a JSON object") }
            return try await client.request("/command", payload: object)
        case "inject": return try await client.command("inject", ["committed": parsed.values["committed"] ?? "", "partial": parsed.values["partial"] ?? ""])
        case "meter": return try await client.command("level", ["level": try parsed.number("level", required: true), "bytes": try parsed.integer("bytes", default: 0)])
        case "fake":
            var fields: [String: Any] = ["behavior": try parsed.argument(0)]
            fields["audioText"] = parsed.values["audio-text"]
            return try await client.command("fake", fields)
        case "replay": return try await client.command("replayAudio", ["audioPath": URL(fileURLWithPath: try parsed.argument(0)).path])
        case "render": return try await client.command("render", ["view": try parsed.argument(0)])
        case "system-paste":
            return try await client.command("systemPaste", parsed.values["target-bundle"].map { ["value": $0] } ?? [:])
        case "globals": return try await client.command("globals", ["enabled": parsed.flags.contains("enabled")])
        case "faults":
            let fields = Dictionary(uniqueKeysWithValues: ["hold-preparation": "holdPreparation", "fail-start": "failStart", "fail-stop": "failStop", "fail-cancel": "failCancel"].map { ($0.value, parsed.flags.contains($0.key)) })
            return try await client.command("inputFaults", fields)
        case "wait":
            var fields: [String: Any] = [:]
            let names = ["phase": "phase", "contains": "textContains", "corrected": "corrected", "requests": "requestCount", "recordings": "recordingCount", "history-id": "historyID", "history-phase": "historyPhase", "model-phase": "modelPhase", "paste-dispatches": "systemPasteDispatches", "timeout": "timeoutSeconds"]
            let numbers: Set<String> = ["requests", "recordings", "paste-dispatches", "timeout"]
            for (flag, field) in names where parsed.values[flag] != nil {
                if numbers.contains(flag) { fields[field] = try parsed.integer(flag) }
                else { fields[field] = try value(flag) }
            }
            return try await client.request("/wait", payload: fields, timeout: max(20, TimeInterval(try parsed.integer("timeout", default: 15)) + 5))
        case "requests":
            if let id = parsed.values["id"] { return try await client.request("/requests/" + id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!) }
            return try await client.request("/requests?limit=\(try parsed.integer("limit", default: 20))&offset=\(try parsed.integer("offset", default: 0))")
        case "ui":
            let view = try parsed.argument(0)
            if parsed.flags.contains("show") { try await client.command("ui", ["view": view, "show": true]) }
            return try await client.request("/ui/" + view)
        case "history":
            let operations = ["transcribe": "transcribeRecording", "cancel": "cancelTranscription", "retry": "retryTranscription", "copy": "copyRecording", "clear-error": "clearRecordingError"]
            guard let name = operations[try parsed.argument(0)] else { throw HarnessError("Unknown history operation") }
            return try await client.command(name, ["recordingID": try parsed.argument(1), "paste": parsed.flags.contains("paste")])
        case "settings": return try await client.command("settings", ["prompt": try value("prompt"), "dictionary": parsed.values["dictionary"] ?? "", "contextLines": parsed.values["context-lines"] ?? "3"])
        case "reset": return try await client.command("reset", ["clearData": parsed.flags.contains("clear-data")])
        default:
            let aliases = ["release": "releaseRequests", "release-preparation": "releasePreparation", "input-failure": "inputFailure", "paste-target": "showPasteTarget", "restore-clipboard": "restoreClipboard"]
            let simple: Set<String> = ["start", "stop", "cancel", "toggle", "quit"]
            guard simple.contains(action) || aliases[action] != nil else { throw HarnessError("Unknown command '\(action)'. Use --help.") }
            return try await client.command(aliases[action] ?? action)
        }
    }

    static func emit(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) + Data([10]))
    }
}

private struct Options {
    let values: [String: String]
    let flags: Set<String>
    let positional: [String]
    init(_ arguments: [String]) throws {
        let boolean: Set<String> = ["enabled", "no-enabled", "hold-preparation", "fail-start", "fail-stop", "fail-cancel", "show", "paste", "clear-data"]
        let valued: Set<String> = ["file", "committed", "partial", "level", "bytes", "audio-text", "target-bundle", "phase", "contains", "corrected", "requests", "recordings", "history-id", "history-phase", "model-phase", "paste-dispatches", "timeout", "id", "limit", "offset", "prompt", "dictionary", "context-lines"]
        var values: [String: String] = [:]; var flags: Set<String> = []; var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                if boolean.contains(key) { flags.insert(key) }
                else {
                    guard valued.contains(key), index + 1 < arguments.count else { throw HarnessError("Unknown or missing option '\(argument)'") }
                    index += 1; values[key] = arguments[index]
                }
            } else { positional.append(argument) }
            index += 1
        }
        self.values = values; self.flags = flags; self.positional = positional
    }
    func required(_ key: String) throws -> String {
        guard let value = values[key] else { throw HarnessError("Missing --\(key)") }; return value
    }
    func argument(_ index: Int) throws -> String {
        guard positional.indices.contains(index) else { throw HarnessError("Missing command argument") }; return positional[index]
    }
    func number(_ key: String, default fallback: Double = 0, required: Bool = false) throws -> Double {
        guard let value = values[key] else { if required { throw HarnessError("Missing --\(key)") }; return fallback }
        guard let number = Double(value), number.isFinite else { throw HarnessError("--\(key) requires a finite number") }; return number
    }
    func integer(_ key: String, default fallback: Int = 0) throws -> Int {
        guard let value = values[key] else { return fallback }
        guard let number = Int(value) else { throw HarnessError("--\(key) requires an integer") }
        return number
    }
}
