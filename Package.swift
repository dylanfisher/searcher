// swift-tools-version: 6.2

import PackageDescription

let strict: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"])
]

let package = Package(
    name: "Searcher",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Base", swiftSettings: strict),
        .target(name: "Browser", dependencies: ["Base"], swiftSettings: strict),
        .target(name: "Interface", dependencies: ["Browser", "Base"], swiftSettings: strict),
        .executableTarget(
            name: "Searcher", dependencies: ["Interface", "Browser", "Base"], swiftSettings: strict),
        .executableTarget(name: "Bench", dependencies: ["Browser", "Base"], swiftSettings: strict),
        .testTarget(name: "BaseTests", dependencies: ["Base"], swiftSettings: strict),
        .testTarget(name: "BrowserTests", dependencies: ["Browser"], swiftSettings: strict),
        .testTarget(name: "BenchTests", dependencies: ["Bench", "Base"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
