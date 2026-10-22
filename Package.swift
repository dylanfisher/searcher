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
            name: "Searcher", dependencies: ["Interface", "Browser", "Base"],
            exclude: ["Info.plist"],
            swiftSettings: strict),
        .executableTarget(name: "Bench", dependencies: ["Browser", "Base"], swiftSettings: strict),
        // Stubs that tests share. Only test targets depend on it.
        .target(name: "TestSupport", dependencies: ["Base"], swiftSettings: strict),
        .testTarget(
            name: "BaseTests", dependencies: ["Base", "TestSupport"], swiftSettings: strict),
        .testTarget(
            name: "BrowserTests", dependencies: ["Browser", "Base", "TestSupport"],
            swiftSettings: strict),
        .testTarget(
            name: "InterfaceTests", dependencies: ["Interface", "Browser", "TestSupport"],
            swiftSettings: strict),
        .testTarget(
            name: "BenchTests", dependencies: ["Bench", "Base", "TestSupport"],
            swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
