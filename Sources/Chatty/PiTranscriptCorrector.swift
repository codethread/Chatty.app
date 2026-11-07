import Darwin
import Foundation

struct PiTranscriptCorrector: TranscriptCorrecting {
    func correct(_ text: String, settings: CorrectionSettings) async throws -> String {
        try Task.checkCancellation()
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        let shell = String(cString: getpwuid(getuid())!.pointee.pw_shell)
        process.executableURL = URL(fileURLWithPath: shell)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // Positional arguments keep dictated text and configured instructions
        // out of shell code; the login shell supplies Pi's PATH and credentials.
        process.arguments = ["-lic", """
        exec pi --model openai/gpt-5.4-mini --thinking off --print --no-session --no-tools --no-extensions --no-skills --no-prompt-templates --no-context-files --system-prompt "$2" -- "$1"
        """, "chatty-correction", text, settings.instructions]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        return try await withTaskCancellationHandler {
            // Drain both pipes concurrently so a full stderr pipe cannot stall Pi.
            let stdout = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
            await Task.detached { process.waitUntilExit() }.value
            let response = await stdout.value
            let diagnostics = await stderr.value
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw PiCorrectionError.failed(process.terminationStatus, String(decoding: diagnostics, as: UTF8.self))
            }
            let corrected = String(decoding: response, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corrected.isEmpty else { throw PiCorrectionError.emptyResponse }
            return corrected
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private enum PiCorrectionError: LocalizedError {
    case failed(Int32, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .failed(let status, let details): "Transcript cleanup failed (pi exit \(status)): \(details.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .emptyResponse: "Transcript cleanup returned no text."
        }
    }
}
