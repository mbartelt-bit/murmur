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
//   MurmurShared   — hand-written Swift the app targets use (CoreClient).
let package = Package(
    name: "MurmurShared",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MurmurShared", targets: ["MurmurShared"])
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
            dependencies: ["MurmurCore"],
            path: "Sources/MurmurShared"
        )
    ]
)
