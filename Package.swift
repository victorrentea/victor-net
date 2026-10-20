// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VictorNet",
    platforms: [.macOS(.v13)],
    targets: [
        // One executable target: the tests `@testable import` it directly.
        .executableTarget(name: "VictorNet"),
        .testTarget(name: "VictorNetTests", dependencies: ["VictorNet"]),
    ]
)
