import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// A warm, cache-aware 600M model. Each session resets decoder state, not weights.
actor LocalSpeechRecognizer {
    private let manager: StreamingNemotronAsrManager
    struct ModelState: Codable, Equatable, Sendable {
        enum Phase: String, Codable { case notDownloaded, downloaded, preparing, ready, failed }
        let phase: Phase
        let message: String
        let progress: Double?
    }
    nonisolated static let defaultModelRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    private let modelRoot: URL
    private var preparation: Task<Void, Error>?
    private var preparationID: UUID?
    private var observers: [UUID: AsyncStream<ModelState>.Continuation] = [:]
    private var state: ModelState

    init(modelRoot: URL = LocalSpeechRecognizer.defaultModelRoot) {
        self.modelRoot = modelRoot
        let downloaded = Self.isDownloaded(at: modelRoot)
        state = ModelState(phase: downloaded ? .downloaded : .notDownloaded,
                           message: downloaded ? "Model downloaded · ready to load" : "Model not downloaded · approximately 626 MB", progress: nil)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        manager = StreamingNemotronAsrManager(configuration: configuration, requestedChunkSize: .ms560)
    }

    nonisolated private static func isDownloaded(at root: URL) -> Bool {
        let directory = root.appendingPathComponent(NemotronChunkSize.ms560.repo.folderName)
        return ["encoder/encoder_int8.mlmodelc/coremldata.bin", "decoder.mlmodelc/coremldata.bin",
                "joint.mlmodelc/coremldata.bin", "tokenizer.json"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    func modelState() -> ModelState { state }
    func changes() -> AsyncStream<ModelState> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(state)
            continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish(_ state: ModelState) {
        self.state = state
        for observer in observers.values { observer.yield(state) }
    }

    func prepare(allowDownload: Bool = false) async throws {
        if let preparation { return try await preparation.value }
        guard allowDownload || Self.isDownloaded(at: modelRoot) else {
            throw LocalModelError.notDownloaded
        }
        let id = UUID()
        preparationID = id
        defer { preparationID = nil }
        publish(ModelState(phase: .preparing, message: Self.isDownloaded(at: modelRoot) ? "Loading local model…" : "Downloading local model…", progress: nil))
        let manager = manager
        let root = modelRoot
        let task = Task {
            try await manager.loadModels(to: root, progressHandler: { [weak self] progress in
                Task { await self?.downloadProgress(progress, id: id) }
            })
        }
        preparation = task
        do {
            try await task.value
            publish(ModelState(phase: .ready, message: "Nemotron 600M ready · English · 560 ms streaming", progress: 1))
        } catch {
            preparation = nil
            publish(ModelState(phase: .failed, message: error.localizedDescription, progress: nil))
            throw error
        }
    }

    private func downloadProgress(_ progress: DownloadProgress, id: UUID) {
        guard preparationID == id else { return }
        let message: String
        switch progress.phase {
        case .listing: message = "Finding model files…"
        case .downloading(let completed, let total): message = "Downloading model · \(completed)/\(total) files"
        case .compiling(let name): message = "Preparing \(name)…"
        }
        publish(ModelState(phase: .preparing, message: message, progress: progress.fractionCompleted))
    }

    func run(
        input: AsyncStream<OwnedPCMBuffer>,
        events: AsyncThrowingStream<DictationEvent, Error>.Continuation,
        onDiagnostic: @Sendable (String) async -> Void = { _ in }
    ) async throws {
        await manager.reset()
        var previous = ""
        var transcript = LocalSpeechTranscript()
        var pauses = SpeechPauseDetector()
        let start = ContinuousClock.now
        var audioSeconds = 0.0
        for await input in input {
            try Task.checkCancellation()
            let seconds = Double(input.buffer.frameLength) / input.buffer.format.sampleRate
            audioSeconds += seconds
            let endsUtterance = pauses.consume(rms: Self.rms(input.buffer), seconds: seconds)
            let decodeStart = ContinuousClock.now
            try await manager.appendAudio(input.buffer)
            try await manager.processBufferedAudio()
            try Task.checkCancellation()
            let text = await manager.getPartialTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
            if text != previous {
                transcript.update(text)
                events.yield(.transcript(transcript.snapshot))
                let elapsed = start.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds]))
                let decode = decodeStart.duration(to: .now).formatted(.units(allowed: [.milliseconds]))
                await onDiagnostic("+\(elapsed) · audio \(String(format: "%.2f", audioSeconds))s · decode \(decode)\n\(text)")
                previous = text
            }
            if endsUtterance {
                let final = try await manager.finish()
                try Task.checkCancellation()
                transcript.finishUtterance(final)
                events.yield(.transcript(transcript.snapshot))
                await onDiagnostic("Sentence closed after 1 second of quiet\n\(transcript.snapshot.text)")
                await manager.reset()
                previous = ""
            }
        }
        try Task.checkCancellation()
        let finalStart = ContinuousClock.now
        let text = try await manager.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        transcript.finishUtterance(text)
        events.yield(.transcript(transcript.snapshot))
        await onDiagnostic("Final flush \(finalStart.duration(to: .now).formatted(.units(allowed: [.milliseconds])))\n\(transcript.snapshot.text)")
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        var sum: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(buffer.frameLength) { sum += samples[frame] * samples[frame] }
        }
        return sqrt(sum / Float(Int(buffer.frameLength) * Int(buffer.format.channelCount)))
    }
}

private enum LocalModelError: LocalizedError {
    case notDownloaded
    var errorDescription: String? { "Download the local model in Speech Recognition settings before using Nemotron." }
}
