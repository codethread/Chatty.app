import AppKit
import Carbon.HIToolbox

/// A user-chosen global keychord (e.g. ⌘⌃0), persisted in config.
struct KeyBinding: Codable, Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    /// Human-readable rendering shown in the menu, captured when the chord is set.
    let label: String

    /// Builds a binding from a captured `keyDown`. Fails when no modifier is held,
    /// since a modifier-less global hotkey would swallow ordinary typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        guard carbon != 0 else { return nil }

        keyCode = UInt32(event.keyCode)
        carbonModifiers = carbon
        label = KeyBinding.makeLabel(flags: flags, keyCode: event.keyCode, chars: event.charactersIgnoringModifiers)
    }

    private static func makeLabel(flags: NSEvent.ModifierFlags, keyCode: UInt16, chars: String?) -> String {
        var result = ""
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }
        result += keyLabel(keyCode: keyCode, chars: chars)
        return result
    }

    private static func keyLabel(keyCode: UInt16, chars: String?) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        if let chars, !chars.isEmpty { return chars.uppercased() }
        return "key \(keyCode)"
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "↩",
        kVK_Tab: "⇥",
        kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
    ]
}

struct AppConfig: Codable, Equatable {
    var recordingShortcut: KeyBinding?
}

/// Persists app configuration as JSON alongside the recordings metadata.
final class ConfigStore {
    private static let url = RecordingStore.appDirectory.appendingPathComponent("config.json")

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    func load() -> AppConfig {
        guard let data = try? Data(contentsOf: Self.url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    @discardableResult
    func setRecordingShortcut(_ binding: KeyBinding?) throws -> AppConfig {
        var config = load()
        config.recordingShortcut = binding
        try save(config)
        return config
    }

    private func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: RecordingStore.appDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        try data.write(to: Self.url, options: .atomic)
    }
}
