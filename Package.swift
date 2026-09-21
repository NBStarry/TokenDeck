// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenDeck",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TokenDeck",
            path: "Sources/UsageBar",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(name: "TokenDeckTests", dependencies: ["TokenDeck"])
    ]
)
