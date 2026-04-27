// swift-tools-version: 6.1
//
// Bumped from 5.9 → 6.1 (2026-04-26, #3) to allow ml-explore/mlx-swift-lm 3.31.3
// — that package requires tools-version 6.1 to vend MLXLLM/MLXLMCommon.
// Swift language mode is pinned to .v5 per-target so existing strict-concurrency
// warnings remain warnings (not errors), matching prior behaviour. Swift compiler
// is 6.2.x; the SwiftLint custom rules `observable_actor_existential_warning`
// and `nonisolated_unsafe_warning` continue to enforce concurrency discipline.
import PackageDescription

let package = Package(
    name: "SpeechToText",
    platforms: [.macOS(.v14)],
    products: [
        .executable(
            name: "SpeechToText",
            targets: ["SpeechToText"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            branch: "main"
        ),
        .package(
            url: "https://github.com/nalexn/ViewInspector.git",
            from: "0.10.0"
        ),
        .package(
            url: "https://github.com/sindresorhus/KeyboardShortcuts",
            from: "2.0.0"
        ),
        // Local-LLM stack for clinical-notes generation (#3).
        // mlx-swift-lm replaces the deprecated mlx-swift-examples (PR #441,
        // 2025-11-11). Pin to .upToNextMinor so a 3.31.x patch release is
        // pulled automatically but a 3.32 minor is opt-in.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-lm",
            .upToNextMinor(from: "3.31.3")
        ),
        // Tokenizers + Hub helpers for loading the bundled-once-downloaded
        // Gemma weights from disk. We do NOT use HubApi for the actual
        // weight download — that is hand-rolled in `ModelDownloader` so
        // the sha256-manifest verification flow is under our control.
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            from: "1.3.0"
        ),
        // Scoped to ReviewScreen + SafetyDisclaimerView snapshot tests
        // (issue #24 / F5). Test-only — does not flow into the app
        // executable target. The snapshot test classes are in CI's
        // by-name skip list because PNG goldens are sensitive to the
        // host macOS version's Core Animation / font-hinting layer
        // (CI is macOS-15, dev + pre-push remote Mac is macOS 26).
        // They run locally and on the remote Mac via pre-push.
        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            .upToNextMajor(from: "1.17.0")
        )
    ],
    targets: [
        .executableTarget(
            name: "SpeechToText",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                "SherpaOnnxSwift"
            ],
            path: "Sources",
            exclude: [],
            resources: [
                .process("Resources/app_logov2.png"),
                .copy("Resources/Models"),
                .copy("Resources/Manipulations"),
                .copy("Resources/Prompts")
            ],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                // Pin language mode to 5 to preserve prior strict-concurrency
                // warning (not error) behaviour now that tools-version is 6.1.
                .swiftLanguageMode(.v5),
                // Frontend flags carried over from the 5.9 manifest. The
                // unsafe-flags wrapper survives the language-mode pin
                // because it operates at the frontend layer.
                .unsafeFlags(["-Xfrontend", "-disable-availability-checking",
                              "-Xfrontend", "-warn-concurrency",
                              "-Xfrontend", "-enable-actor-data-race-checks"])
            ]
        ),
        // sherpa-onnx Swift API wrapper target
        .target(
            name: "SherpaOnnxSwift",
            dependencies: ["sherpa_onnx"],
            path: "Resources/sherpa-onnx-swift-api",
            exclude: [
                // Exclude example/demo files that have @main entry points
                "add-punctuation-online.swift",
                "add-punctuations.swift",
                "compute-speaker-embeddings.swift",
                "decode-file-non-streaming.swift",
                "decode-file-sense-voice-with-hr.swift",
                "decode-file-t-one-streaming.swift",
                "decode-file.swift",
                "dolphin-ctc-asr.swift",
                "fire-red-asr.swift",
                "generate-subtitles.swift",
                "keyword-spotting-from-file.swift",
                "medasr-ctc.swift",
                "omnilingual-asr-ctc.swift",
                "speaker-diarization.swift",
                "speech-enhancement-gtcrn.swift",
                "spoken-language-identification.swift",
                "streaming-hlg-decode-file.swift",
                "test-version.swift",
                "tts-kitten-en.swift",
                "tts-kokoro-en.swift",
                "tts-kokoro-zh-en.swift",
                "tts-matcha-en.swift",
                "tts-matcha-zh.swift",
                "tts-vits.swift",
                "wenet-ctc-asr.swift",
                "zipformer-ctc-asr.swift"
            ]
        ),
        // sherpa-onnx xcframework binary target
        .binaryTarget(
            name: "sherpa_onnx",
            path: "Frameworks/sherpa-onnx.xcframework"
        ),
        .testTarget(
            name: "SpeechToTextTests",
            dependencies: [
                "SpeechToText",
                "SherpaOnnxSwift",
                .product(name: "ViewInspector", package: "ViewInspector"),
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            path: "Tests/SpeechToTextTests",
            // Snapshot golden PNGs and the Snapshots README are read off
            // disk by `pointfreeco/swift-snapshot-testing` using
            // `#filePath`-relative paths — they must not be bundled as
            // SPM resources (which would copy them into `.bundle` and
            // hide them from the test). Excluding the entire
            // `__Snapshots__` tree also keeps the test bundle slim.
            exclude: [
                "Snapshots/__Snapshots__",
                "Snapshots/README.md"
            ],
            resources: [
                .copy("Fixtures")
            ],
            swiftSettings: [
                // Mirror the main target's language-mode pin so existing
                // pre-Swift-6-mode tests (e.g. AudioCaptureServiceTests'
                // non-Sendable level callback) keep compiling now that
                // tools-version is 6.1.
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
