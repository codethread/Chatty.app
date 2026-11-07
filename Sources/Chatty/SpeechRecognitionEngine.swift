import Foundation

enum SpeechRecognitionEngine: String, Codable, CaseIterable, Sendable {
    case apple, nemotron

    var title: String {
        switch self {
        case .apple: "Apple · built in"
        case .nemotron: "Nemotron 600M · local streaming"
        }
    }
}
