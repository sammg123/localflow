// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalFlow",
    platforms: [
        .macOS("26.0") // SpeechAnalyzer + FoundationModels need macOS 26
    ],
    dependencies: [
        // Pin exact: pre-1.0, the ASR API has changed across 0.x releases.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
    ],
    targets: [
        .executableTarget(
            name: "LocalFlow",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/LocalFlow",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Headless pipeline test: audio file -> Parakeet -> FoundationModels. No TCC needed.
        .executableTarget(
            name: "localflow-smoke",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/LocalFlowSmoke",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
