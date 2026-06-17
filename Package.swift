// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chatty",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Chatty", targets: ["Chatty"])
    ],
    targets: [
        .executableTarget(
            name: "Chatty",
            path: "Sources/Chatty",
            exclude: ["Info.plist"]
        )
    ]
)
