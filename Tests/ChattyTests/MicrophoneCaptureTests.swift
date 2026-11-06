import AVFoundation
import Darwin
import Foundation
import Speech
import Testing
@testable import Chatty

struct MicrophoneCaptureTests {
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
