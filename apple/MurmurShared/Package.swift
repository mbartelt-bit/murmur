// swift-tools-version:5.9
import PackageDescription

// MurmurShared wraps the Rust core for the iOS app.
//
//   MurmurCoreFFI  — binary target: apple/Frameworks/MurmurCore.xcframework, the static
//                    libmurmur_core.a slices plus the C header + module map. Produced by
//                    `scripts/build-core-mobile.sh ios`, gitignored; run that script once
//                    before the first Xcode build or package resolution fails here.
//   MurmurCore     — the generated Swift bindings (Sources/MurmurCore/Generated, also
//                    written by that script and gitignored).
//   MurmurShared   — hand-written Swift the app targets use (CoreClient, AppGroup,
//                    Settings, Keychain, Handoff, and the GRDB history store).
//   MurmurKeyboardCore — the keyboard extension's logic (layout model, shift, the App Group
//                    hand-off controller). No UI, no UIKit.
//
// LINK GRAPH RULE: the MurmurKeyboard extension links the MurmurKeyboardCore and MurmurShared
// products and never MurmurCore. A keyboard may not record (design spec §6.1, App Store
// guideline 4.4.1), so nothing under Sources/MurmurKeyboardCore may import MurmurCore,
// AVFoundation, or Speech — the Rust core and the audio/speech files stay out of the
// extension's address space. (MurmurShared itself still imports MurmurCore for the provider
// mapping in Settings; peeling that apart so the extension stops pulling the Rust core in
// transitively is a later split — this comment is the contract in the meantime.)
//
// GRDB backs the transcripts history in the App Group container. Its own Package.swift
// declares swift-tools-version 6.1, which Xcode 26.6 satisfies; ours stays at 5.9 so our
// targets keep building in the Swift 5 language mode.
let package = Package(
    name: "MurmurShared",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MurmurShared", targets: ["MurmurShared"]),
        .library(name: "MurmurKeyboardCore", targets: ["MurmurKeyboardCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1")
    ],
    targets: [
        .binaryTarget(
            name: "MurmurCoreFFI",
            path: "../Frameworks/MurmurCore.xcframework"
        ),
        .target(
            name: "MurmurCore",
            dependencies: ["MurmurCoreFFI"],
            path: "Sources/MurmurCore"
        ),
        .target(
            name: "MurmurShared",
            dependencies: [
                "MurmurCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MurmurShared"
        ),
        .target(
            name: "MurmurKeyboardCore",
            dependencies: ["MurmurShared"],
            path: "Sources/MurmurKeyboardCore"
        )
    ]
)
