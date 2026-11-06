// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Chatty",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Chatty", targets: ["Chatty"])
    ],
    targets: [
        .executableTarget(
            name: "Chatty",
            path: "Sources/Chatty",
            exclude: ["Info.plist"]
        ),
        .testTarget(name: "ChattyTests", dependencies: ["Chatty"])
    ]
)
