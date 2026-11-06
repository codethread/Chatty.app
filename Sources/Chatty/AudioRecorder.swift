import AVFoundation
import Foundation
import OSLog

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private static let logger = Logger(subsystem: "local.chatty.Chatty", category: "Recording")
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var lastMeterEmit: TimeInterval = 0
    var onLevelChange: ((Float) -> Void)?
    var onFileSizeChange: ((Int64) -> Void)?

    var isRecording: Bool { recorder?.isRecording == true }

    func start(fileURL url: URL) async throws {
        guard !isRecording else { return }
        Self.logger.notice("Start requested; microphone authorization=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        Self.logger.notice("Microphone access granted=\(granted)")
        guard granted else { throw AudioError.microphoneDenied }

        let input = AVCaptureDevice.default(for: .audio)?.localizedName ?? "No default audio input"
        Self.logger.notice("Default input: \(input, privacy: .public)")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        Self.logger.notice("Requested settings: \(String(describing: settings), privacy: .public); destination=\(url.path, privacy: .public)")
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            Self.logger.notice("Recorder initialized; settings: \(String(describing: recorder.settings), privacy: .public)")
            let prepared = recorder.prepareToRecord()
            Self.logger.notice("prepareToRecord returned \(prepared)")
            guard prepared else { throw AudioError.couldNotStart }
            let started = recorder.record()
            Self.logger.notice("record returned \(started); isRecording=\(recorder.isRecording)")
            guard started else { throw AudioError.couldNotStart }
            self.recorder = recorder
        } catch {
            Self.logger.error("Recording start failed: \(String(reflecting: error as NSError), privacy: .public)")
            throw error
        }

        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitMeter() }
        }
    }

    func stop() throws -> URL {
        guard let recorder, recorder.isRecording else { throw AudioError.notRecording }
        let url = recorder.url
        finishRecording(recorder)
        return url
    }

    func cancel() throws {
        guard let recorder, recorder.isRecording else { throw AudioError.notRecording }
        let url = recorder.url
        finishRecording(recorder)
        try FileManager.default.removeItem(at: url)
    }

    private func finishRecording(_ recorder: AVAudioRecorder) {
        Self.logger.notice("Stopping recording at \(recorder.currentTime) seconds")
        recorder.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        self.recorder = nil
        onLevelChange?(0)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        let details = error.map { String(reflecting: $0 as NSError) } ?? "AVFoundation supplied no error details"
        Task { @MainActor in
            Self.logger.error("Encoder error: \(details, privacy: .public)")
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            Self.logger.notice("Recorder finished; success=\(flag)")
        }
    }

    private func emitMeter() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let detected: Float = power > Settings.meterSilenceThreshold ? 1 : 0
        if let size = try? FileManager.default.attributesOfItem(atPath: recorder.url.path)[.size] as? NSNumber {
            onFileSizeChange?(size.int64Value)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if detected > 0 || now - lastMeterEmit > Settings.meterDebounce {
            lastMeterEmit = now
            onLevelChange?(detected)
        }
    }
}

enum AudioError: LocalizedError {
    case microphoneDenied
    case couldNotStart
    case notRecording

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone permission denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .couldNotStart: "Could not start recording."
        case .notRecording: "No active recording."
        }
    }
}
