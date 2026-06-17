import Foundation

struct Recording: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let audioFilename: String
    var transcript: String?
    var transcriptionError: String?

    var audioURL: URL { RecordingStore.recordingsDirectory.appendingPathComponent(audioFilename) }
}

final class RecordingStore {
    static let appDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Chatty", isDirectory: true)
    }()

    static let recordingsDirectory: URL = appDirectory.appendingPathComponent("Recordings", isDirectory: true)

    private static let metadataURL = appDirectory.appendingPathComponent("recordings.json")

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() throws {
        try FileManager.default.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
    }

    func makeRecordingURL(id: UUID = UUID()) throws -> (id: UUID, url: URL) {
        try FileManager.default.createDirectory(at: Self.recordingsDirectory, withIntermediateDirectories: true)
        return (id, Self.recordingsDirectory.appendingPathComponent("\(id.uuidString).m4a"))
    }

    func addRecording(id: UUID, audioURL: URL, createdAt: Date = Date()) throws -> Recording {
        var recordings = try load()
        let recording = Recording(
            id: id,
            createdAt: createdAt,
            audioFilename: audioURL.lastPathComponent,
            transcript: nil,
            transcriptionError: nil
        )
        recordings.insert(recording, at: 0)
        try save(recordings)
        return recording
    }

    func load() throws -> [Recording] {
        guard FileManager.default.fileExists(atPath: Self.metadataURL.path) else { return [] }
        let data = try Data(contentsOf: Self.metadataURL)
        return try decoder.decode([Recording].self, from: data)
            .sorted { $0.createdAt > $1.createdAt }
    }

    func updateTranscript(for id: UUID, transcript: String) throws {
        try update(id: id) { recording in
            recording.transcript = transcript
            recording.transcriptionError = nil
        }
    }

    func updateError(for id: UUID, message: String) throws {
        try update(id: id) { recording in
            recording.transcriptionError = message
        }
    }

    func clearError(for id: UUID) throws {
        try update(id: id) { recording in
            recording.transcriptionError = nil
        }
    }

    @discardableResult
    func pruneRecordingsOlderThan(days: Int, now: Date = Date()) throws -> Int {
        guard days >= 0 else { throw RecordingStoreError.invalidRetentionDays(days) }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        let recordings = try load()
        let expired = recordings.filter { $0.createdAt < cutoff }
        let retained = recordings.filter { $0.createdAt >= cutoff }

        for recording in expired {
            if FileManager.default.fileExists(atPath: recording.audioURL.path) {
                try FileManager.default.removeItem(at: recording.audioURL)
            }
        }

        if expired.isEmpty == false {
            try save(retained)
        }
        return expired.count
    }

    private func update(id: UUID, mutate: (inout Recording) -> Void) throws {
        var recordings = try load()
        guard let index = recordings.firstIndex(where: { $0.id == id }) else {
            throw RecordingStoreError.recordingNotFound(id)
        }
        mutate(&recordings[index])
        try save(recordings)
    }

    private func save(_ recordings: [Recording]) throws {
        try FileManager.default.createDirectory(at: Self.appDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(recordings.sorted { $0.createdAt > $1.createdAt })
        try data.write(to: Self.metadataURL, options: .atomic)
    }
}

enum RecordingStoreError: LocalizedError {
    case recordingNotFound(UUID)
    case invalidRetentionDays(Int)

    var errorDescription: String? {
        switch self {
        case .recordingNotFound(let id): "Recording not found: \(id.uuidString)"
        case .invalidRetentionDays(let days): "Recording retention days must be zero or greater; got \(days)."
        }
    }
}
