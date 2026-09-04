# Murmur Mobile MM0 — Core extraction + phone shells

**Goal:** Pull the provider-agnostic dictation pipeline out of the Tauri crate into `crates/murmur-core`, expose it to Swift and Kotlin with UniFFI, and stand up an iOS app shell and an Android app shell that each call the core end to end on a simulator/emulator. Desktop behaviour and all existing tests stay green.

**Spec:** `docs/superpowers/specs/2026-09-03-murmur-mobile-design.md` (sections 3, 4, 5, 11, 12, 13). Read it first.

**Branch / worktree:** `feat/mobile-core` checked out at `~/murmur-wt/mobile-core` (created from `feat/mobile-design`). Do not touch `~/murmur` (it holds Matt's uncommitted hotkey work).

**Model split:** implementers run as Opus subagents, one task each; Fable (the controlling session) reviews every task diff before the next task starts.

## Global constraints (verbatim from the spec)

- `murmur-core` has **no Tauri, store, or keychain dependency**; callers pass configuration in; the crate holds no state.
- Errors: one `CoreError` enum (`Network`, `Rejected`, `Http(u16)`, `Empty`) so all three front ends show the same three user-facing messages that exist today in `src-tauri/src/engines.rs` (`"Couldn't reach {provider} — check your connection."`, `"That key was rejected — double-check it and try again."`, `"Couldn't verify the key (HTTP {n})."`).
- `clean_text` **never fails**: cloud → `RuleCleanup` fallback.
- Desktop behaviour must not change; the existing 38 Rust tests move with the code; the 24 Vitest tests keep passing.
- Bundle id `com.murmur.app` (iOS app) / package `com.murmur.app` (Android). Apple team `X9PU63GUAN`. Min iOS 17. Min SDK 28, target SDK 35.
- Build outputs (`MurmurCore.xcframework`, `jniLibs/*.so`, generated bindings) are gitignored; `xcodebuild` and `./gradlew` are the only entry points.
- Rust mobile targets, `cargo-ndk`, Android SDK 35 + NDK 27.2.12479018 + emulator image are already installed on this Mac (`~/Library/Android/sdk`). Java: `/Applications/Android Studio.app/Contents/jbr/Contents/Home`.

## Verification gate for the whole milestone

```bash
cd ~/murmur-wt/mobile-core && . "$HOME/.cargo/env"
cargo test --workspace --exclude murmur            # core tests (murmur = the tauri crate needs dist/)
npm run build && cargo test --manifest-path src-tauri/Cargo.toml && cargo build --manifest-path src-tauri/Cargo.toml
npx vitest run
scripts/build-core-mobile.sh ios && scripts/build-core-mobile.sh android
xcodebuild -project apple/Murmur.xcodeproj -scheme Murmur -destination 'platform=iOS Simulator,name=<an available iPhone>' test
cd android && ./gradlew assembleDebug testDebugUnitTest
```
Plus one manual check per platform: the shell app shows `Cleaned: Hello world.` and the Groq key URL on screen.

---

## Task 1 — `murmur-core` crate + workspace (Rust only)

**Files**
- Create `Cargo.toml` (root, workspace): `members = ["crates/murmur-core", "src-tauri"]`, `resolver = "2"`. Move `src-tauri/Cargo.lock` to the root (`git mv`). Tauri CLI and the existing CI commands (`--manifest-path src-tauri/Cargo.toml`) keep working in a workspace.
- Create `crates/murmur-core/Cargo.toml`:
  - `[lib] crate-type = ["lib", "staticlib", "cdylib"]`, `name = "murmur_core"`.
  - deps: `uniffi = "0.32"` (features `["tokio"]`), `tokio = { version = "1", features = ["rt-multi-thread", "macros"] }`, `reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "http2", "json", "multipart"] }`, `serde`, `serde_json`, `thiserror = "2"`, `zeroize`, `anyhow`.
  - optional `whisper-rs = { version = "0.16", optional = true }` behind feature `whisper` (macOS adds `features = ["metal"]` via `[target.'cfg(target_os = "macos")'.dependencies]`, exactly as `src-tauri/Cargo.toml` does today).
  - feature `cli = ["uniffi/cli"]`.
  - `[[bin]] name = "uniffi-bindgen" path = "src/bin/uniffi-bindgen.rs" required-features = ["cli"]`.
- Create `crates/murmur-core/build.rs`: `fn main() { uniffi::generate_scaffolding("src/murmur_core.udl").unwrap_or(()); }` is **not** used; we use proc macros only, so no build.rs is needed. (Stated so nobody adds one.)
- Create `crates/murmur-core/src/lib.rs`: `uniffi::setup_scaffolding!();` plus `pub mod` lines and the exported functions listed under **Produces**.
- Move (git mv, then adjust `use` paths) from `src-tauri/src/`:
  - `resample.rs` → `crates/murmur-core/src/resample.rs`
  - `wav.rs` → `crates/murmur-core/src/wav.rs`
  - `provider.rs` → `crates/murmur-core/src/provider.rs` (add `#[derive(uniffi::Enum)]` and `pub fn key_page_url(&self) -> &'static str` returning `https://console.groq.com/keys` / `https://platform.openai.com/api-keys`, copied from `src/components/EngineSettings.tsx` `PROVIDER_INFO`).
  - `audio.rs` **helpers only** (`rms`, `peak`, `stereo_to_mono` + their tests) → `crates/murmur-core/src/audio_math.rs`. `start_capture`/`Capture` (cpal) stay in `src-tauri/src/audio.rs`, which now `pub use murmur_core::audio_math::{rms, peak, stereo_to_mono};`.
  - `cleanup/rules.rs` → `crates/murmur-core/src/cleanup/rules.rs` (unchanged, incl. tests).
  - `cleanup/cloud.rs` → `crates/murmur-core/src/cleanup/cloud.rs`, converted to **async** `reqwest::Client` (same prompt constant, same JSON body).
  - `stt/cloud.rs` → `crates/murmur-core/src/stt/cloud.rs`, converted to **async** (`reqwest::multipart`).
  - `stt/local.rs` → `crates/murmur-core/src/stt/local.rs` behind `#[cfg(feature = "whisper")]` (unchanged).
  - The `verify_provider` HTTP logic from `src-tauri/src/engines.rs` → `crates/murmur-core/src/verify.rs`, async, returning `Result<(), CoreError>`.
- Create `crates/murmur-core/src/error.rs`:
  ```rust
  #[derive(Debug, thiserror::Error, uniffi::Error)]
  #[uniffi(flat_error)]
  pub enum CoreError {
      #[error("Couldn't reach {provider} — check your connection.")] Network { provider: String },
      #[error("That key was rejected — double-check it and try again.")] Rejected,
      #[error("Couldn't verify the key (HTTP {status}).")] Http { status: u16 },
      #[error("Nothing to transcribe.")] Empty,
  }
  ```
- Create `crates/murmur-core/src/bin/uniffi-bindgen.rs`: `fn main() { uniffi::uniffi_bindgen_main() }`.
- Modify `src-tauri/Cargo.toml`: add `murmur-core = { path = "../crates/murmur-core", features = ["whisper"] }`; drop `reqwest`'s `blocking` + `multipart` + `charset` features (keep `stream`, `json`, `rustls-tls`, `http2` for `model.rs`); drop `whisper-rs` from `src-tauri` (it now comes via core).
- Modify `src-tauri/src/stt/mod.rs` and `src-tauri/src/cleanup/mod.rs`: keep the `make_engine(app)` factories and the `stt_choice`/`cleanup_choice` helpers + tests; the cloud engine impls become thin adapters that call `murmur_core` async fns via `tauri::async_runtime::block_on(...)` (the pipeline worker is a plain std thread, so `block_on` is safe there). `SttEngine`/`CleanupEngine` traits stay in `src-tauri` (desktop-only dynamic dispatch).
- Modify `src-tauri/src/engines.rs`: `verify_provider` command becomes `tauri::async_runtime::block_on(murmur_core::verify_provider(cfg)).map(|_| "Connected".to_owned()).map_err(|e| e.to_string())`.
- Modify `src-tauri/src/lib.rs`: remove `mod provider; mod resample; mod wav;` (now `use murmur_core::...` where needed).
- Modify `.github/workflows/ci.yml`: add `- run: cargo test -p murmur-core` before the tauri crate steps; add a job step `rustup target add aarch64-apple-ios aarch64-linux-android` on macOS and `cargo build -p murmur-core --target aarch64-apple-ios --no-default-features` (the Android target build lands in Task 2's script; CI for it is Task 5).

**Produces (exact, used by Tasks 2–4)** — all in `crates/murmur-core/src/lib.rs`:
```rust
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)] pub enum Provider { OpenAI, Groq }
#[derive(uniffi::Record, Clone)] pub struct CloudConfig { pub provider: Provider, pub api_key: String }
#[derive(uniffi::Record, Clone, Debug, PartialEq)] pub struct CleanResult { pub raw: String, pub clean: String, pub used_cloud: bool }

#[uniffi::export] pub fn key_page_url(provider: Provider) -> String;
#[uniffi::export] pub fn resample_to_16k(samples: Vec<f32>, in_rate: u32, channels: u16) -> Vec<f32>;   // stereo_to_mono if channels >= 2, then resample_linear(.., in_rate, 16000)
#[uniffi::export(async_runtime = "tokio")] pub async fn transcribe_cloud(audio_16k_mono: Vec<f32>, cfg: CloudConfig, prompt: String) -> Result<String, CoreError>; // Err(Empty) on empty input
#[uniffi::export(async_runtime = "tokio")] pub async fn clean_text(raw: String, cloud: Option<CloudConfig>) -> CleanResult;
#[uniffi::export(async_runtime = "tokio")] pub async fn verify_provider(cfg: CloudConfig) -> Result<(), CoreError>;
```
HTTP status mapping (shared by transcribe/clean/verify): connection error → `Network{provider}`; 401/403 → `Rejected`; other non-2xx → `Http{status}`.

**Tests (crates/murmur-core, `cargo test -p murmur-core`)**
- All moved tests pass unchanged.
- `resample_to_16k_downmixes_stereo_then_resamples`: 4 interleaved stereo samples at 32 kHz → 1 mono sample at 16 kHz.
- `clean_text_without_cloud_uses_rules`: `clean_text("um hello world", None).await == CleanResult{raw:"um hello world", clean:"Hello world.", used_cloud:false}`.
- `clean_text_falls_back_when_cloud_unreachable`: config with `api_key:"x"` and `Provider::Groq` but `base_url` overridden to `http://127.0.0.1:9` (add `#[cfg(test)] fn clean_with_base_url(...)` internal helper so the test doesn't need network) → `used_cloud == false`, clean == rules output.
- `transcribe_cloud_empty_is_error`: empty audio → `Err(CoreError::Empty)`.
- `verify_maps_401_to_rejected` using a tiny `std::net::TcpListener` that replies `HTTP/1.1 401` (no mock crate needed).
- Desktop: `cargo test --manifest-path src-tauri/Cargo.toml` still green (needs `npm run build` first), `cargo build` green, `npx vitest run` green.

**Commit** as `refactor(core): extract murmur-core workspace crate with UniFFI exports`.

---

## Task 2 — `scripts/build-core-mobile.sh`

**Files**
- Create `scripts/build-core-mobile.sh` (bash, `set -euo pipefail`), usage `build-core-mobile.sh ios|android [--debug]`.
- Create `crates/murmur-core/uniffi.toml`:
  ```toml
  [bindings.swift]
  module_name = "MurmurCore"
  ffi_module_name = "MurmurCoreFFI"
  [bindings.kotlin]
  package_name = "app.murmur.core"
  cdylib_name = "murmur_core"
  ```
- Modify `.gitignore`: add `apple/Frameworks/`, `apple/MurmurShared/Sources/MurmurCore/Generated/`, `android/app/src/main/jniLibs/`, `android/app/src/main/java/app/murmur/core/`.

**Behaviour**
- Env: `JAVA_HOME` defaults to the Android Studio JBR path above; `ANDROID_HOME` to `$HOME/Library/Android/sdk`; `ANDROID_NDK_HOME` to `$ANDROID_HOME/ndk/27.2.12479018`. Print them.
- `ios`: `cargo build -p murmur-core --release --no-default-features --target aarch64-apple-ios` and `--target aarch64-apple-ios-sim`; run `cargo run -p murmur-core --features cli --bin uniffi-bindgen -- generate --library target/aarch64-apple-ios/release/libmurmur_core.dylib --language swift --out-dir target/uniffi/swift`; then assemble `target/uniffi/ios-headers/{MurmurCoreFFI.h, module.modulemap}` (rename `MurmurCoreFFI.modulemap` → `module.modulemap`), copy `MurmurCore.swift` into `apple/MurmurShared/Sources/MurmurCore/Generated/`, and `xcodebuild -create-xcframework -library target/aarch64-apple-ios/release/libmurmur_core.a -headers target/uniffi/ios-headers -library target/aarch64-apple-ios-sim/release/libmurmur_core.a -headers target/uniffi/ios-headers -output apple/Frameworks/MurmurCore.xcframework` (rm -rf the old one first).
- `android`: `cargo ndk -t arm64-v8a -t x86_64 -o android/app/src/main/jniLibs build -p murmur-core --release --no-default-features`; then `cargo run -p murmur-core --features cli --bin uniffi-bindgen -- generate --library target/aarch64-linux-android/release/libmurmur_core.so --language kotlin --out-dir android/app/src/main/java` (produces `app/murmur/core/murmur_core.kt`).
- Note for the implementer: `--no-default-features` matters because the `whisper` feature must never be compiled for mobile (cmake + whisper.cpp cross-compiles are out of scope).

**Test:** run both modes on this Mac; both must exit 0 and leave the artifacts above in place. Add a `scripts/README.md` line documenting the two commands.

**Commit** as `build(core): mobile build script producing MurmurCore.xcframework and Android jniLibs + bindings`.

---

## Task 3 — iOS app shell (`apple/`)

**Files**
- Create `apple/project.yml` (XcodeGen spec; `brew install xcodegen` if missing). This file is the source of truth; commit both it and the generated `apple/Murmur.xcodeproj` (`xcodegen generate` from `apple/`).
  - `name: Murmur`, `options: { bundleIdPrefix: com.murmur, deploymentTarget: { iOS: "17.0" }, developmentLanguage: en }`.
  - `settings: { base: { DEVELOPMENT_TEAM: X9PU63GUAN, SWIFT_VERSION: "5.10", CODE_SIGN_STYLE: Automatic } }`.
  - `packages: { MurmurShared: { path: MurmurShared } }`.
  - target `Murmur` (`type: application`, `platform: iOS`, sources `Murmur`, `dependencies: [{ package: MurmurShared }]`, info plist keys: `NSMicrophoneUsageDescription` = "Murmur needs the microphone to transcribe your dictation.", `NSSpeechRecognitionUsageDescription` = "Murmur transcribes on your device using Apple speech recognition.", `CFBundleURLTypes` with scheme `murmur`, `UILaunchScreen: {}`), `preBuildScripts: [{ name: "Build MurmurCore", script: "cd \"$SRCROOT/..\" && scripts/build-core-mobile.sh ios", outputFiles: ["$(SRCROOT)/Frameworks/MurmurCore.xcframework"] }]`.
  - target `MurmurTests` (`type: bundle.unit-test`, sources `MurmurTests`, `dependencies: [{ target: Murmur }]`).
  - `schemes: { Murmur: { build: { targets: { Murmur: all } }, test: { targets: [MurmurTests] } } }`.
- Create `apple/MurmurShared/Package.swift` (swift-tools 5.9): product `MurmurShared`; targets: `MurmurCore` (path `Sources/MurmurCore`, depends on binary target `MurmurCoreFFI` at `../Frameworks/MurmurCore.xcframework`) and `MurmurShared` (path `Sources/MurmurShared`, depends on `MurmurCore`). `Sources/MurmurCore/Generated/` holds the generated `MurmurCore.swift` (gitignored; Task 2 writes it).
- Create `apple/MurmurShared/Sources/MurmurShared/CoreClient.swift`:
  ```swift
  import MurmurCore
  public enum CoreClient {
      public static func groqKeyPage() -> String { keyPageUrl(provider: .groq) }
      public static func cleanLocally(_ raw: String) async -> CleanResult { await cleanText(raw: raw, cloud: nil) }
  }
  ```
- Create `apple/Murmur/MurmurApp.swift` (`@main struct MurmurApp: App` → `WindowGroup { HomeView() }`) and `apple/Murmur/HomeView.swift`: a VStack with the title "Murmur", a `Text` showing `CoreClient.groqKeyPage()`, and a button "Run core" that awaits `CoreClient.cleanLocally("um hello world")` and shows `Cleaned: \(result.clean)`. Use the indigo accent `Color(red: 0.388, green: 0.4, blue: 0.945)` for the button.
- Create `apple/Murmur/Assets.xcassets` with an empty `AppIcon.appiconset` + `Contents.json` (real icon is MM4).
- Create `apple/MurmurTests/CoreClientTests.swift`:
  ```swift
  import XCTest
  @testable import Murmur
  import MurmurShared
  final class CoreClientTests: XCTestCase {
      func testKeyPageIsGroqConsole() { XCTAssertEqual(CoreClient.groqKeyPage(), "https://console.groq.com/keys") }
      func testRulesCleanupThroughFFI() async {
          let r = await CoreClient.cleanLocally("um hello world")
          XCTAssertEqual(r.clean, "Hello world."); XCTAssertFalse(r.usedCloud)
      }
  }
  ```

**Test:** `xcrun simctl list devices available | grep iPhone` to pick a name, then `xcodebuild -project apple/Murmur.xcodeproj -scheme Murmur -destination 'platform=iOS Simulator,name=<name>' test` passes; `xcrun simctl launch` the app and confirm it renders (a `simctl io screenshot` saved to the scratchpad is the evidence).

**Commit** as `feat(ios): SwiftUI app shell calling murmur-core through UniFFI`.

---

## Task 4 — Android app shell (`android/`)

**Files**
- Create `android/settings.gradle.kts`, `android/build.gradle.kts` (AGP 8.7+, Kotlin 2.1+, Compose compiler plugin), `android/gradle.properties` (`android.useAndroidX=true`, `org.gradle.jvmargs=-Xmx2g`), Gradle wrapper 8.11 (`brew install gradle` then `gradle wrapper --gradle-version 8.11` inside `android/`; commit the wrapper jar + scripts), `android/local.properties` is gitignored (script writes `sdk.dir`).
- Create `android/app/build.gradle.kts`: `namespace = "com.murmur.app"`, `applicationId = "com.murmur.app"`, `minSdk = 28`, `targetSdk = 35`, `compileSdk = 35`, Compose BOM, `implementation("net.java.dev.jna:jna:5.15.0@aar")` (UniFFI Kotlin bindings need JNA), `kotlinx-coroutines-android`; a task:
  ```kotlin
  val buildRustCore by tasks.registering(Exec::class) {
      workingDir = rootDir.parentFile
      commandLine("scripts/build-core-mobile.sh", "android")
  }
  tasks.named("preBuild") { dependsOn(buildRustCore) }
  ```
- Create `android/app/src/main/AndroidManifest.xml` (single `MainActivity`, `android:exported="true"`, launcher intent; `INTERNET` permission).
- Create `android/app/src/main/java/com/murmur/app/MainActivity.kt` (Compose `setContent { HomeScreen() }`) and `HomeScreen.kt`: title "Murmur", `Text(keyPageUrl(Provider.GROQ))`, a button "Run core" that launches `cleanText("um hello world", null)` in `rememberCoroutineScope()` and shows `Cleaned: ${result.clean}`. Accent `Color(0xFF6366F1)`.
- Create `android/app/src/main/java/com/murmur/app/CoreClient.kt`: `object CoreClient { fun groqKeyPage() = keyPageUrl(Provider.GROQ); suspend fun cleanLocally(raw: String) = cleanText(raw, null) }`.
- Create `android/app/src/test/java/com/murmur/app/CoreClientTest.kt` — JVM unit tests cannot load the Android `.so`, so this test covers the one piece of pure Kotlin: a `formatCleaned(result: CleanResult): String` helper in `HomeScreen.kt` that returns `"Cleaned: <clean>"`, asserting on a hand-built `CleanResult("um hi", "Hi.", false)`. The FFI itself is verified on the emulator (below).
- Add `android/README.md` with the three commands: `./gradlew assembleDebug`, `./gradlew testDebugUnitTest`, emulator run.

**Test:** `cd android && ./gradlew assembleDebug testDebugUnitTest` green. Create an AVD once (`avdmanager create avd -n murmur35 -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_7`), boot it headless (`emulator -avd murmur35 -no-window -no-audio &`, wait for `adb shell getprop sys.boot_completed` = 1), `./gradlew installDebug`, `adb shell am start -n com.murmur.app/.MainActivity`, tap "Run core" via `adb shell input tap` or just assert the URL text renders via `adb exec-out screencap -p > scratchpad/android.png`. Kill the emulator afterwards.

**Commit** as `feat(android): Compose app shell calling murmur-core through UniFFI`.

---

## Task 5 — CI + docs

**Files**
- Modify `.github/workflows/ci.yml`: on macOS add steps `rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-linux-android x86_64-linux-android`, `cargo install cargo-ndk`, `brew install xcodegen`, `scripts/build-core-mobile.sh ios`, `xcodebuild ... test` against `platform=iOS Simulator,name=iPhone 16` (adjust to what `macos-latest` offers), `android-actions/setup-android@v3` + NDK 27.2.12479018, `scripts/build-core-mobile.sh android`, `cd android && ./gradlew assembleDebug testDebugUnitTest`. Keep the Windows job as is (desktop only).
- Modify `docs/HANDOFF.md`: add a "Mobile (MM0 landed)" section: worktree convention, the five commands from the verification gate, where generated files go, and the reminder that `whisper` is desktop-only.
- Modify `README.md`: replace the Tauri template text with three lines: what Murmur is, desktop build (link to HANDOFF), mobile build (link to the spec + this plan).

**Test:** push the branch; CI green on macOS and Windows.

**Commit** as `ci: build murmur-core for mobile targets, run iOS and Android shell tests`.

---

## Review checklist (Fable runs after each task)

1. Desktop unchanged: `git diff --stat feat/mobile-design -- src-tauri src` touches only adapter code; no behavioural edits to `pipeline.rs`, `hotkey.rs`, `ptt_key.rs`, `insert.rs`, `permissions.rs`.
2. No secrets or absolute user paths committed (`grep -rn "matthewbartelt\|sk-\|gsk_" --exclude-dir=node_modules --exclude-dir=target .` empty except this plan's worktree note).
3. Generated files and build outputs are gitignored; `git status` clean after a full build.
4. Every new public FFI symbol appears in Task 1's **Produces** block with the same name and types.
