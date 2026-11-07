// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Chatty",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Chatty", targets: ["Chatty"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.6")
    ],
    targets: [
        .executableTarget(
            name: "Chatty",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Chatty",
            exclude: ["Info.plist"]
        ),
        .testTarget(name: "ChattyTests", dependencies: ["Chatty"])
    ]
)
