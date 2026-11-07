import AVFoundation
import Darwin
import Foundation
import Speech
import Testing
@testable import Chatty

struct MicrophoneCaptureTests {
    @Test(arguments: [44_100.0, 48_000.0, 16_000.0])
    func realProcessorDownmixesResamplesMetersAndFinalizesAAC(sampleRate: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingURL = directory.appendingPathComponent("recording.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let analysisFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let processor = try MicrophoneBufferProcessor(recordingURL: recordingURL, inputFormat: format, analysisFormat: analysisFormat)
        let captured = AsyncStream<AnalyzerInput>.makeStream()
        let analysis = AsyncStream<AnalyzerInput>.makeStream()
        let events = AsyncThrowingStream<DictationEvent, Error>.makeStream()
        for packet in 0..<10 {
            let count = Int(sampleRate / 10)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for frame in 0..<count {
                buffer.floatChannelData![0][frame] = 0
                buffer.floatChannelData![1][frame] = 0.1 * sin(Float(packet * count + frame) * 2 * .pi * 240 / Float(sampleRate))
            }
            captured.continuation.yield(AnalyzerInput(buffer: buffer))
        }
        captured.continuation.finish()
        try await processor.run(input: captured.stream, analysis: analysis.continuation, events: events.continuation)
        events.continuation.finish()
        var totalFrames = 0
        var energy: Float = 0
        for await packet in analysis.stream {
            #expect(packet.buffer.format == analysisFormat)
            totalFrames += Int(packet.buffer.frameLength)
            for frame in 0..<Int(packet.buffer.frameLength) { energy += abs(packet.buffer.floatChannelData![0][frame]) }
        }
        #expect((15_990...16_010).contains(totalFrames))
        #expect(energy > 10)
        var levels: [Float] = []
        var sizes: [Int64] = []
        for try await event in events.stream {
            if case .level(let value) = event { levels.append(value) }
            if case .fileSize(let value) = event { sizes.append(value) }
        }
        #expect(!levels.isEmpty && levels.allSatisfy { (0...1).contains($0) })
        #expect(levels.contains { $0 > 0 })
        #expect(sizes.contains { $0 > 0 })
        let audio = try AVAudioFile(forReading: recordingURL)
        #expect(audio.fileFormat.channelCount == 1)
        #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(abs(Double(audio.length) / audio.processingFormat.sampleRate - 1) < 0.1)
    }

    @MainActor
    @Test(arguments: [AVAudioChannelCount(1), AVAudioChannelCount(2)])
    func captureCreatedOnMainActorRunsOffMainAndOwnsItsSamples(channels: AVAudioChannelCount) async throws {
        let captured = AsyncStream<AnalyzerInput>.makeStream()
        let callback = MicrophoneDictationService.makeCaptureCallback(into: captured.continuation) { error in
            Issue.record(error)
        }

        await Task.detached {
            #expect(pthread_main_np() == 0)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: channels)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
            buffer.frameLength = 4
            for channel in 0..<Int(channels) {
                for frame in 0..<4 {
                    buffer.floatChannelData![channel][frame] = Float(channel + frame) / 4
                }
            }
            callback(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
            // The engine reuses its buffer after the callback returns.
            for channel in 0..<Int(channels) {
                for frame in 0..<4 { buffer.floatChannelData![channel][frame] = 99 }
            }
            captured.continuation.finish()
        }.value

        var iterator = captured.stream.makeAsyncIterator()
        let input = try #require(await iterator.next())
        #expect(input.buffer.frameLength == 4)
        #expect(input.buffer.format.channelCount == channels)
        for channel in 0..<Int(channels) {
            for frame in 0..<4 {
                #expect(input.buffer.floatChannelData![channel][frame] == Float(channel + frame) / 4)
            }
        }
    }
}
