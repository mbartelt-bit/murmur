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
//   MurmurSharedBase — plain Foundation: the App Group, the settings model, the dictation
//                    hand-off codec. No Rust core, no GRDB, no AVFoundation, no Speech.
//   MurmurShared   — everything else the app needs (CoreClient, Keychain, the GRDB history
//                    store, audio capture, the speech engines) plus `ProviderId.core`, the
//                    one bridge from the settings model to the core's provider enum. It
//                    re-exports MurmurSharedBase, so app code keeps saying `import
//                    MurmurShared` and sees AppGroup/Settings/Handoff exactly as before.
//   MurmurKeyboardCore — the keyboard extension's logic (layout model, shift, the App Group
//                    hand-off controller). No UI, no UIKit.
//   MurmurKeyboardUI — the extension's SwiftUI views (KeyboardView, KeyCap, StatusStrip). A
//                    library rather than files in the extension target so the app-hosted
//                    MurmurTests can instantiate the view and catch layout crashes.
//
// LINK GRAPH RULE: the MurmurKeyboard extension links MurmurKeyboardUI, MurmurKeyboardCore
// and MurmurSharedBase — never MurmurShared and never MurmurCore. A keyboard may not record
// (design spec §6.1, App Store guideline 4.4.1) and has roughly a 50–70 MB ceiling
// (§2 constraint 5), so nothing under Sources/MurmurKeyboardCore, Sources/MurmurKeyboardUI
// or Sources/MurmurSharedBase may import MurmurCore, AVFoundation, Speech, or GRDB: the Rust
// core and the audio/speech files stay out of the extension's address space entirely.
//
// GRDB backs the transcripts history in the App Group container. Its own Package.swift
// declares swift-tools-version 6.1, which Xcode 26.6 satisfies; ours stays at 5.9 so our
// targets keep building in the Swift 5 language mode.
let package = Package(
    name: "MurmurShared",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MurmurShared", targets: ["MurmurShared"]),
        .library(name: "MurmurSharedBase", targets: ["MurmurSharedBase"]),
        .library(name: "MurmurKeyboardCore", targets: ["MurmurKeyboardCore"]),
        .library(name: "MurmurKeyboardUI", targets: ["MurmurKeyboardUI"])
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
            name: "MurmurSharedBase",
            path: "Sources/MurmurSharedBase"
        ),
        .target(
            name: "MurmurShared",
            dependencies: [
                "MurmurSharedBase",
                "MurmurCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MurmurShared"
        ),
        .target(
            name: "MurmurKeyboardCore",
            dependencies: ["MurmurSharedBase"],
            path: "Sources/MurmurKeyboardCore"
        ),
        .target(
            name: "MurmurKeyboardUI",
            dependencies: ["MurmurKeyboardCore", "MurmurSharedBase"],
            path: "Sources/MurmurKeyboardUI"
        )
    ]
)
