import Foundation

// Called on the independently extracted, signed distribution artifact.
struct InvalidArchive: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
guard CommandLine.arguments.count == 2 else { throw InvalidArchive("Usage: swift scripts/verify-release.swift /path/to/Chatty.app") }
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any]
guard info["LSUIElement"] as? Bool == true, info["CFBundleIdentifier"] as? String == "local.chatty.Chatty" else {
    throw InvalidArchive("Release must be the production menu-bar app")
}
let binary = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/Chatty"))
for marker in ["CHATTY_HARNESS_READY", "chatty-local-fake"] {
    guard binary.range(of: Data(marker.utf8)) == nil else { throw InvalidArchive("Debug harness leaked into release: \(marker)") }
}
print("Production archive: menu-bar identity and debug exclusion verified")
