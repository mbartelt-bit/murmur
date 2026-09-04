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

## `ios-testflight.sh`

Archives the iOS app (Release, automatic signing under team X9PU63GUAN), bumps `CFBundleVersion` for the app and both extensions to the current UTC minute, and uploads to App Store Connect with `xcodebuild -exportArchive` (`destination: upload`) using the ASC API key. `--no-upload` writes the `.ipa` to `target/ios/export/` instead. Prerequisites and the device checklist: `apple/README.md` → TestFlight.

## `android-play-upload.sh [--no-upload] [--track …] [--status …]`

Builds the signed Android App Bundle and pushes it to Google Play's internal-testing
track — the Android twin of `ios-testflight.sh`.

```bash
scripts/android-play-upload.sh                                   # bundleRelease + internal track
scripts/android-play-upload.sh --no-upload                       # just the .aab
scripts/android-play-upload.sh --track production --status draft # a real release, left as a draft
```

`versionCode` is `$MURMUR_VERSION_CODE` when set, otherwise the current UTC minute
(`yyMMddHHmm`), so every upload is strictly newer than the last; `versionName` stays
`0.1.0`. Signing comes from `android/keystore.properties` (gitignored — see
`android/keystore.properties.example`), and the script stops before Gradle if that file
is missing rather than building an .aab Play would reject.

## `play-upload.mjs --aab <path> [flags]`

The upload itself: Google Play Developer API v3, dependency-free (a service account only
needs an RS256 JWT, which `node:crypto` mints). Usually reached through
`android-play-upload.sh`; run it directly to re-upload an .aab you already have.

| Flag | Default | |
|---|---|---|
| `--aab` | — | required |
| `--package` | `com.murmur.app` | |
| `--track` | `internal` | |
| `--status` | `completed` on `internal`, else `draft` | `draft`, `completed`, `inProgress`, `halted` |
| `--rollout` | — | required with `--status inProgress` (e.g. `0.1`) |
| `--notes` | — | a file, ≤ 500 chars |
| `--dry-run` | — | authenticate, read the track, upload nothing |

The service-account JSON comes from `$PLAY_SERVICE_ACCOUNT`, else
`~/murmur-android-signing/play-service-account.json`, else
`~/arkhe-android-signing/play-service-account.json` — the same Google Play developer
account owns both apps, so one service account can be granted access to each. Never
commit or print it.

Until the Play Console has an app for `com.murmur.app` and that service account holds
**Release manager** on it, every run stops at:

```
✗ POST /androidpublisher/v3/applications/com.murmur.app/edits → 403
  The caller does not have permission
```

`android/README.md` → **Play (internal testing)** lists the console steps that clear it.
