// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OpenType",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OpenType", targets: ["OpenType"])
    ],
    dependencies: [
        // Markdown rendering for every assistant-authored text surface (the
        // unified voice surface's result card, the Q&A tab, the Agent tab) —
        // see `AssistantMarkdownView` and
        // `docs/superpowers/specs/2026-08-13-hud-morph-result-surface-design.md` §3.
        // Statically linked by SwiftPM, so `scripts/build-app.sh` needs no
        // change; a release build does need network access on first resolve.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1")
    ],
    targets: [
        .executableTarget(
            name: "OpenType",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/OpenType",
            swiftSettings: [
                .define("OPENTYPE_APP")
            ]
        ),
        .testTarget(
            name: "OpenTypeTests",
            dependencies: ["OpenType"],
            path: "Tests/OpenTypeTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
