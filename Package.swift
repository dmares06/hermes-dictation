// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WhisperDictCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "WhisperDictCore", targets: ["WhisperDictCore"]),
    ],
    targets: [
        .target(name: "WhisperDictCore"),
        .testTarget(name: "WhisperDictCoreTests", dependencies: ["WhisperDictCore"]),
    ]
)
