import Foundation

/// A completed edit can intentionally remove the entire supplied passage.
struct TranscriptEdit: Codable, Sendable {
    let text: String

    static func decode(_ data: Data) throws -> String {
        try JSONDecoder().decode(Self.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
