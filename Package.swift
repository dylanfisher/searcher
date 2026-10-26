// swift-tools-version: 6.2

import PackageDescription

let strict: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"])
]

let package = Package(
    name: "Searcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BeepInterpose", type: .dynamic, targets: ["BeepInterpose"])
    ],
    targets: [
        .target(name: "Base", swiftSettings: strict),
        .target(name: "Browser", dependencies: ["Base"], swiftSettings: strict),
        .target(name: "Interface", dependencies: ["Browser", "Base"], swiftSettings: strict),
        .executableTarget(
            name: "Searcher", dependencies: ["Interface", "Browser", "Base"],
            exclude: ["Info.plist", "AppIcon.svg"],
            swiftSettings: strict),
        .executableTarget(name: "Bench", dependencies: ["Browser", "Base"], swiftSettings: strict),
        // Stubs that tests share. Only test targets depend on it.
        .target(
            name: "TestSupport", dependencies: ["Base"],
            swiftSettings: strict + [.enableExperimentalFeature("SymbolLinkageMarkers")]),
        // Silences the alert sound in test runs and reports each one. A dylib because dyld only
        // interposes from images loaded at launch; scripts/test inserts it.
        .target(
            name: "BeepInterpose",
            swiftSettings: strict + [
                .enableExperimentalFeature("SymbolLinkageMarkers"),
                .enableExperimentalFeature("Extern"),
            ]),
        // Browser-type stubs that tests share: clipboard, monitor, system actions, prompts.
        .target(
            name: "BrowserTestSupport", dependencies: ["Browser", "TestSupport"],
            swiftSettings: strict),
        .testTarget(
            name: "BaseTests", dependencies: ["Base", "TestSupport"], swiftSettings: strict),
        .testTarget(
            name: "BrowserTests",
            dependencies: ["Browser", "Base", "TestSupport", "BrowserTestSupport"],
            swiftSettings: strict),
        .testTarget(
            name: "InterfaceTests",
            dependencies: ["Interface", "Browser", "TestSupport", "BrowserTestSupport"],
            swiftSettings: strict),
        .testTarget(
            name: "BenchTests", dependencies: ["Bench", "Base", "TestSupport"],
            swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
