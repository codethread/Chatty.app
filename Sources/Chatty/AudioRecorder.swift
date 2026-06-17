import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var lastMeterEmit: TimeInterval = 0
    var onLevelChange: ((Float) -> Void)?

    var isRecording: Bool { recorder?.isRecording == true }

    func start() async throws {
        guard !isRecording else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw AudioError.microphoneDenied }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chatty-")
            .appendingPathExtension(UUID().uuidString)
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        guard recorder.record() else { throw AudioError.couldNotStart }
        self.recorder = recorder

        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emitMeter() }
        }
    }

    func stop() throws -> URL {
        guard let recorder, recorder.isRecording else { throw AudioError.notRecording }
        let url = recorder.url
        recorder.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        self.recorder = nil
        onLevelChange?(0)
        return url
    }

    private func emitMeter() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let detected: Float = power > Settings.meterSilenceThreshold ? 1 : 0
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
