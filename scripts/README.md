# scripts

## `build-core-mobile.sh <ios|android> [--debug]`

Cross-compiles `crates/murmur-core` for a phone platform and regenerates its
UniFFI bindings. Xcode runs it as a pre-build phase and Gradle as the
`buildRustCore` task, so you rarely need to run it by hand — but both modes are
safe to re-run at any time and always rewrite the same outputs.

Both modes build with `--no-default-features`: the `whisper` feature needs cmake
and whisper.cpp, which we do not cross-compile. Local inference is desktop-only.

```bash
scripts/build-core-mobile.sh ios        # release (default)
scripts/build-core-mobile.sh android --debug
```

### Outputs (all gitignored)

| | |
|---|---|
| `apple/Frameworks/MurmurCore.xcframework` | `ios-arm64` + `ios-arm64-simulator` static libs and the `MurmurCoreFFI` headers/modulemap |
| `apple/MurmurShared/Sources/MurmurCore/Generated/MurmurCore.swift` | Swift bindings (`import MurmurCore`) |
| `android/app/src/main/jniLibs/{arm64-v8a,x86_64}/libmurmur_core.so` | JNI libraries |
| `android/app/src/main/java/app/murmur/core/murmur_core.kt` | Kotlin bindings (`package app.murmur.core`) |

Intermediates land in `target/uniffi/`.

### Requirements

Rust targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-linux-android`,
`x86_64-linux-android`; Xcode (iOS); `cargo-ndk` plus Android NDK 27.2.12479018
(Android). The script prints the `JAVA_HOME`, `ANDROID_HOME` and
`ANDROID_NDK_HOME` it resolved and fails with a specific message when a tool is
missing. Export any of the three to override the defaults.
