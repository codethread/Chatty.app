import Foundation

struct HotkeyError: LocalizedError {
    let operation: String
    let status: Int32
    var errorDescription: String? { "Could not \(operation) (macOS status \(status)). Choose another recording shortcut if it is already in use." }
}
