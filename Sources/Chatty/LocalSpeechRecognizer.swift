import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Speech

/// A warm, cache-aware 600M model. Each session resets decoder state, not weights.
actor LocalSpeechRecognizer {
    private let manager: StreamingNemotronAsrManager
    private var preparation: Task<Void, Error>?

    init() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        manager = StreamingNemotronAsrManager(configuration: configuration, requestedChunkSize: .ms560)
    }

    func prepare() async throws {
        if let preparation { return try await preparation.value }
        let manager = manager
        let task = Task { try await manager.loadModels() }
        preparation = task
        do {
            try await task.value
        } catch {
            preparation = nil
            throw error
        }
    }

    func run(
        input: AsyncStream<AnalyzerInput>,
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
