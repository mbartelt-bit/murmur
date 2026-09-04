# Murmur Mobile — iOS + Android Design

**Date:** 2026-09-03
**Status:** Design for review (architectural path). Scope approved by Matt: both platforms, iOS first, published under ARKHE Software, LLC (Apple team `X9PU63GUAN`).
**Builds on:** `docs/superpowers/specs/2026-06-27-murmur-dictation-app-design.md` (the macOS product) and `docs/HANDOFF.md` (current code).

## 1. Summary

Murmur today is a macOS menubar app: hold a key, speak, cleaned text pastes at the cursor.
This spec brings the same promise to iPhone and Android: **speak into any text field on your
phone, with as few taps as the platform allows, using the same engines and the same keys.**

The mobile product has three surfaces per platform:

| Surface | iOS | Android |
|---|---|---|
| Containing app (settings, engines, keys, history, onboarding) | Tauri 2 + existing React UI | Tauri 2 + existing React UI |
| Recording surface (where the mic actually runs) | Native SwiftUI screen inside the containing app | Native Kotlin view inside the keyboard itself |
| Text-insertion surface | Custom keyboard extension (voice-first) + Action Button App Intent | Custom keyboard (input method service, voice-first) |

Everything that turns audio into clean text — cloud STT, cleanup, provider config, WAV
encoding, resampling — is extracted from the Tauri crate into a **`murmur-core` Rust library**
and exposed to Swift and Kotlin through UniFFI. macOS keeps using the same crate.

### Non-negotiables carried over from the product spec
- **Local-first and free by default.** On phones the free local engine is the platform's own
  on-device speech recognition (Apple `SpeechAnalyzer` / `SFSpeechRecognizer`, Android
  on-device `SpeechRecognizer`). No 142 MB download, no signup.
- **BYOK cloud optional.** Groq and OpenAI keys work exactly as on the Mac, stored in the
  platform's secure store, never in plaintext.
- **Never lose words.** Every transcript is written to history before insertion; if
  insertion is impossible the text is on the clipboard and shown on screen.

## 2. Platform constraints that decided the design

These are hard facts verified on 2026-09-03; the design does not fight them.

1. **iOS keyboard extensions cannot record audio.** Apple blocks the microphone from
   extensions (console error `CMSUtility_IsAllowedToStartRecording ... NOT allowed ... because it
   is an extension`), unchanged through iOS 26. Recording must happen in the containing app.
   Sources: Apple forum threads 742601, 775077, 800500.
2. **iOS 26.4 removed every way for a keyboard to send the user back to the host app.** Apple DTS
   confirmed there is no public API (FB22247647). Shipping keyboards now show a "swipe back to
   your app" screen. Murmur does the same and never uses private APIs. Source: thread 826851.
3. **Android input methods may record audio themselves** (this is how Gboard voice typing works),
   so no app switch is needed on Android.
4. **Tauri regenerates the Xcode project only on `tauri ios init`**, from an XcodeGen `project.yml`.
   `bundle.iOS.template` in `tauri.conf.json` points at a custom template, which is how the
   keyboard extension target is added. `xcodegen` must be installed (`brew install xcodegen`).
5. **Keyboard extensions have roughly a 50–70 MB memory ceiling.** No model loading in the
   extension, ever. The extension only draws UI and inserts text.

## 3. Repository layout after this work

```
murmur/
  crates/
    murmur-core/          # NEW: engines, providers, wav, resample, cleanup rules; UniFFI exports
  src-tauri/              # desktop + mobile containing app (Tauri). Depends on murmur-core.
    src/                  # macOS/Windows-specific code stays here (hotkey, ptt_key, insert, …)
    gen/apple/            # generated once; committed; contains the Keyboard extension target
    gen/android/          # generated once; committed; contains the IME
    ios-template/project.yml   # custom XcodeGen template (adds MurmurKeyboard target + App Group)
    tauri-plugin-murmur-native/  # in-repo Tauri mobile plugin: Swift + Kotlin (secrets, speech, permissions)
  apple/
    MurmurKeyboard/       # Swift keyboard extension sources
    MurmurShared/         # Swift package: App Group handoff codec, Keychain access-group wrapper
    MurmurRecorder/       # SwiftUI recording screen + AppIntent (linked into the containing app)
  android/
    ime/                  # Kotlin: MurmurInputMethodService + voice view + state machine
  src/                    # React UI, now responsive (desktop window + phone)
```

`Cargo.toml` at the repo root becomes a workspace (`crates/murmur-core`, `src-tauri`).

## 4. `murmur-core` (Rust)

**Purpose:** the provider-agnostic pipeline, with no Tauri, store, or keychain dependency.
Callers pass configuration in; the crate holds no state.

Moved from `src-tauri/src/`: `stt/cloud.rs`, `stt/local.rs` (behind a `whisper` cargo feature, off
on mobile), `cleanup/rules.rs`, `cleanup/cloud.rs`, `provider.rs`, `wav.rs`, `resample.rs`,
`audio::{rms, peak, stereo_to_mono}`. The `SttEngine` / `CleanupEngine` traits move too.

UniFFI-exported surface (proc-macro style, `uniffi::setup_scaffolding!()`):

```rust
#[derive(uniffi::Enum)] pub enum Provider { OpenAI, Groq }
#[derive(uniffi::Record)] pub struct CloudConfig { provider: Provider, api_key: String }
#[derive(uniffi::Record)] pub struct CleanResult { raw: String, clean: String, used_cloud: bool }

#[uniffi::export]
pub fn transcribe_cloud(audio_16k_mono: Vec<f32>, cfg: CloudConfig, prompt: String) -> Result<String, CoreError>;
#[uniffi::export]
pub fn clean_text(raw: String, cloud: Option<CloudConfig>) -> CleanResult;   // never fails: cloud → rules fallback
#[uniffi::export]
pub fn resample_to_16k(samples: Vec<f32>, in_rate: u32, channels: u16) -> Vec<f32>;
#[uniffi::export]
pub fn verify_provider(cfg: CloudConfig) -> Result<(), CoreError>;         // same semantics as today's command
#[uniffi::export]
pub fn key_page_url(p: Provider) -> String;
```

- The crate exposes both a **blocking** and an **async** (`reqwest` non-blocking) API; UniFFI
  exports the async versions so Swift `await` / Kotlin `suspend` callers never block a UI thread.
- Errors: one `CoreError` enum (`Network`, `Rejected`, `Http(u16)`, `Empty`) so all three
  front ends show the same three user-facing messages that exist today in `engines.rs`.
- `src-tauri` becomes a thin adapter: its commands read the store and secrets, then call
  `murmur-core`. Desktop behaviour must not change; the existing 38 Rust tests move with the code.

**Bindings build:** `uniffi-bindgen` generates `murmur_core.swift` + a modulemap into
`apple/MurmurShared/Generated/` and `uniffi/murmur/core.kt` into `android/ime/src/main/java/`.
An XCFramework (`MurmurCore.xcframework`, targets `aarch64-apple-ios` +
`aarch64-apple-ios-sim`) and an Android `.so` per ABI (`aarch64-linux-android`,
`x86_64-linux-android` for the emulator) are produced by `scripts/build-core-mobile.sh`.
These are build outputs, gitignored, and rebuilt by the Xcode/Gradle build phases.

## 5. Containing app (Tauri 2 on iOS and Android)

- Generated with `tauri ios init` / `tauri android init`. Identifier stays `com.murmur.app`.
- The existing React screens are reused. `App.tsx` gains a phone layout: a single scrolling
  column, 100 % width cards, a top tab bar (Home · History · Settings) on mobile only, detected by
  `navigator.userAgent` at startup via a `platform` value exported from a new
  `src/lib/platform.ts` (`"macos" | "windows" | "ios" | "android"`), sourced from a Tauri command.
- Desktop-only components are not rendered on mobile: `HotkeySetting`, the fn-key badge, the
  Accessibility/Input Monitoring onboarding steps.
- **Mobile onboarding** (new `src/components/MobileOnboarding.tsx`), in order:
  1. Microphone (request via native plugin; deep-link to Settings if denied).
  2. Speech recognition permission (iOS only; needed by the local engine).
  3. Engine: **Local (free, on-device)** is preselected and needs nothing. Groq/OpenAI reuse
     `EngineSettings` unchanged (key entry, Get-your-key link, live verify).
  4. Enable the keyboard: an illustrated step that deep-links to the platform keyboard settings
     and polls until Murmur is enabled (iOS: also requires **Allow Full Access**, with the honest
     one-line reason: "so the keyboard can read your dictation from Murmur and your keys").
  5. iOS only, optional: **Action Button** step shown on iPhone 15 Pro and newer, linking to
     Settings → Action Button with the "Murmur: Dictate" shortcut preselected.
  6. Test dictation: an in-app "Try it" field that runs the full pipeline.
- **History** reuses `HistoryList` and the existing SQLite schema; the mobile path appends a
  `source` column (`"keyboard" | "action-button" | "in-app"`) via migration v2.

### `tauri-plugin-murmur-native` (in-repo mobile plugin, Swift + Kotlin)
Commands the React UI calls on mobile, replacing the macOS-only ones in `permissions.rs` /
`secrets.rs`:

| Command | iOS | Android |
|---|---|---|
| `secret_set/get/delete` | Keychain, access group `group.com.murmur.app` (readable by the extension) | `EncryptedSharedPreferences` (same app process as the IME) |
| `mic_status` / `request_mic` | `AVAudioApplication.requestRecordPermission` | `RECORD_AUDIO` runtime request |
| `speech_status` / `request_speech` | `SFSpeechRecognizer.requestAuthorization` | n/a (returns granted) |
| `keyboard_enabled` | checks `AppleKeyboards` for the extension bundle id; Full Access is known because the extension writes a `fullAccess` heartbeat to the App Group each time it appears (`hasFullAccess`), and the app reads it | `InputMethodManager.enabledInputMethodList` |
| `open_keyboard_settings` | `app-settings:` URL | `ACTION_INPUT_METHOD_SETTINGS` |
| `platform` | `"ios"` | `"android"` |
| `run_test_dictation` | presents the native recording screen, resolves with the result | starts the recording view in-app |

Engine choice and the local/cloud setting continue to live in `settings.json` (store plugin).
On iOS the store file is written into the App Group container so the extension can read the
selected engine; on Android the IME shares the app's files directory.

## 6. iOS: keyboard extension + recording round trip

### 6.1 Keyboard (`MurmurKeyboard`, `UIInputViewController`, Swift)
Voice-first, not a full QWERTY (the platform auto-switches to the system keyboard for number,
phone, decimal, and email fields, and users switch back with the globe for typing).

Layout, top to bottom, ~216 pt tall, follows system light/dark and the indigo accent:
- A status strip: "Tap the mic to dictate" · while a result is pending: the transcript preview
  with **Insert** (in case auto-insert did not fire) and **Discard**.
- A large centred **mic button** (56 pt), a globe (next keyboard), delete, space, return.
- Nothing else. No suggestions bar, no settings inside the keyboard.

Behaviour:
1. Mic tap → write `{session: UUID, requestedAt, hostHint: nil}` to the App Group
   (`UserDefaults(suiteName: "group.com.murmur.app")`, key `pending`) → open
   `murmur://dictate?session=<uuid>` through the responder-chain `UIApplication.open` path
   used by shipping keyboards. If Full Access is off, the keyboard shows "Turn on Full Access in
   Settings" with a button that opens Settings instead.
2. On every `viewWillAppear` / `textDidChange`, read `result` from the App Group. If its
   `session` matches the pending one and it has not been inserted: `textDocumentProxy.insertText`,
   mark inserted, clear pending. Match by session so a stale result from an earlier round trip is
   never inserted into the wrong field.
3. If the user returns and no result exists yet (they came back early), keep the strip in
   "Listening in Murmur…" state and poll the App Group every 500 ms for up to 60 s.

### 6.2 Recording screen (`MurmurRecorder`, SwiftUI, inside the containing app)
Presented by the AppDelegate the instant the URL arrives, as a full-screen cover **over the
Tauri webview, before the webview finishes loading**, so cold-start latency is native.
- Starts recording immediately (AVAudioEngine, 16 kHz mono float).
- Shows the same visual language as the Mac HUD: pulsing red dot while recording, translucent
  squiggle while transcribing. A live level meter drives the dot.
- Stops on: tap anywhere, 1.5 s of silence after speech (auto-stop, on by default, toggle in
  settings), or 120 s hard cap.
- Pipeline: platform speech (`SpeechAnalyzer` on iOS 26+, `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition = true` on iOS 17–25) **or** `murmur-core.transcribe_cloud`
  when the engine is Groq/OpenAI → `murmur-core.clean_text` → history row → `result` to the
  App Group **and** to the clipboard.
- Final state: the cleaned text in a card, a copy confirmation, and the line **"Swipe back to
  your app — the text will be inserted."** with an 8 s auto-dismiss of the sheet. No attempt is
  made to switch apps programmatically (constraint 2).
- Errors follow the Mac rules: cloud failure falls back to local speech, then to rule cleanup;
  an empty transcript shows "Didn't catch that" and inserts nothing.

### 6.3 Action Button / Shortcuts (`DictateIntent`, App Intents)
- `AppShortcutsProvider` exposes **"Dictate with Murmur"** (`openAppWhenRun = true`), so it can
  be bound to the Action Button, Back Tap, a Lock Screen control, or Siri.
- It opens the same recording screen with `source = action-button`. Delivery: clipboard always;
  App Group `result` with `session = "intent"` so the Murmur keyboard, if active in the host app,
  inserts it on return. Otherwise the user pastes.

### 6.4 Project wiring
- `src-tauri/ios-template/project.yml` adds target `MurmurKeyboard` (type
  `app-extension`, `NSExtensionPointIdentifier = com.apple.keyboard-service`,
  `RequestsOpenAccess = YES`, `PrimaryLanguage = en-US`), links `MurmurShared` and
  `MurmurCore.xcframework`, and gives both targets the App Group and Keychain access group
  entitlements. Bundle ids: `com.murmur.app` (app), `com.murmur.app.keyboard` (extension).
- Info.plist strings: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.
  URL scheme `murmur`. Minimum iOS 17.
- `PrivacyInfo.xcprivacy` declares the required-reason APIs used (UserDefaults, file timestamps).

## 7. Android: voice keyboard (input method service)

### 7.1 `MurmurInputMethodService` (Kotlin, `android/ime/`)
- Registered in the manifest with `android.permission.BIND_INPUT_METHOD`, `method.xml` with
  `supportsSwitchingToNextInputMethod = true`, `isDefault = false`.
- Voice-first view (Compose, in a `ComposeView` hosted by the IME): the same strip + big mic +
  globe + delete + space + return layout as iOS, sized ~220 dp.
- On show, if **Auto-listen** is on (default on) recording starts immediately; otherwise on mic tap.
- Recording runs in the IME process with `AudioRecord` (16 kHz mono PCM). `RECORD_AUDIO` is
  granted in the containing app during onboarding; if missing, the view shows "Open Murmur to
  allow the microphone" with a launch button.
- Stop: tap, 1.5 s silence, or 120 s cap. Then platform on-device `SpeechRecognizer`
  (`EXTRA_PREFER_OFFLINE = true`; if the device has no offline model, fall through to cloud if a key
  exists, else show "Download offline speech in Google settings" with a deep link) **or**
  `murmur-core` cloud STT → `clean_text` → `currentInputConnection.commitText` → history row.
- After commit: if **Return to previous keyboard** is on (default on), call
  `switchToPreviousInputMethod()` so Gboard comes straight back. The whole round trip is: globe,
  speak, done.
- The main app's cleanup/engine settings and secrets are shared because the IME runs in the app's
  own process and sandbox.

### 7.2 Containing app wiring
- `gen/android` is committed; the IME lives in the app module (not a separate Gradle module) so
  Tauri's build stays untouched; Kotlin sources are added under
  `gen/android/app/src/main/java/com/murmur/app/ime/` via a symlink to `android/ime/` so the
  sources are reviewed in one place.
- `build-core-mobile.sh` drops the UniFFI Kotlin binding and `libmurmur_core.so` into `jniLibs`.
- Min SDK 28 (needed for `switchToPreviousInputMethod`), target SDK current.

## 8. Data flow (one dictation, iOS keyboard path)

1. Keyboard writes `pending{session}` → opens `murmur://dictate?session=…`.
2. Recorder starts mic within ~300 ms of app foreground; user speaks; auto-stop.
3. STT (local or cloud) → cleanup → SQLite history (`source = keyboard`) → App Group
   `result{session, raw, clean, at}` + clipboard.
4. Recorder shows "Swipe back to your app". User swipes back.
5. Host app resumes; the keyboard re-appears; `viewWillAppear` sees a matching `result` →
   `insertText(clean)` → clears both keys.

Android path: globe → Murmur → (auto) record → STT → cleanup → `commitText` →
`switchToPreviousInputMethod`. One tap total if auto-listen and auto-return are on.

## 9. Error handling

| Condition | Behaviour |
|---|---|
| Mic denied | Recorder/keyboard shows one line + Settings deep link; nothing recorded. |
| Speech permission denied (iOS) | Local engine unavailable → prompt to grant, or to pick Groq. |
| Full Access off (iOS) | Keyboard shows the Full Access explainer and a Settings button; mic button disabled. |
| Cloud key invalid/offline | Falls back to platform local speech; cleanup falls back to rules; banner in history row. |
| Empty/silence | "Didn't catch that." Nothing inserted; nothing written to clipboard. |
| Result never picked up (user never swiped back) | Text stays on clipboard and in history; `pending` expires after 10 minutes so it can't insert later. |
| App killed mid-recording | Recorder writes samples to a temp file every 2 s; on next launch offers "Finish last dictation". |
| Android no offline speech model | Deep link to Google speech settings; cloud if configured. |

## 10. Security & privacy

- Keys: iOS Keychain access group / Android `EncryptedSharedPreferences`, never in
  `settings.json`, never in the App Group defaults, never logged.
- The App Group `result` holds dictated text only until inserted or for 10 minutes.
- Cloud requests go only to the two hard-coded provider base URLs, as today.
- Store disclosures: microphone, speech recognition, Full Access (iOS), and the exact list of
  where audio goes (device only, or the user's chosen provider) go in the App Privacy labels, the
  Play Data Safety form, and a privacy policy page published at a URL Matt owns
  (`https://murmur.app/privacy` is the placeholder; the listing step confirms the real one).

## 11. Testing strategy

- **Rust:** existing 38 tests move to `murmur-core` unchanged; new tests for `clean_text`
  fallback, `resample_to_16k` channel handling, and the UniFFI error mapping.
- **Swift (XCTest, runs on simulator in CI):** the App Group handoff codec (session matching,
  expiry, insert-once), the recorder state machine (start/stop/auto-stop/cap) with a fake audio
  source, and the keyboard's Full-Access-off rendering.
- **Kotlin (JUnit + Robolectric):** the IME state machine, `commitText` + switch-back ordering
  with a fake `InputConnection`, and silence detection.
- **React (Vitest):** mobile onboarding steps gate correctly per platform; desktop components are
  absent on mobile; existing 24 tests keep passing.
- **CI:** the existing matrix adds `cargo build --target aarch64-apple-ios` and
  `--target aarch64-linux-android` for `murmur-core`, an `xcodebuild test` on the simulator, and
  `./gradlew testDebugUnitTest`.
- **Device gates (only Matt):** mic prompts, Full Access, real keyboard insertion into Messages,
  Safari, and Notes; Action Button; swipe-back timing; Gboard round trip on a physical Android
  device or emulator with Google speech services.

## 12. Milestones

Each milestone gets its own implementation plan and lands on `main` behind a green CI.

- **MM0 — Core extraction + scaffolds.** `murmur-core` workspace crate, UniFFI bindings,
  `tauri ios init` / `tauri android init` committed, both containing apps boot on simulator and
  emulator showing the React settings UI in phone layout. Desktop unchanged.
- **MM1 — iOS containing app.** Native plugin (secrets, permissions, speech), mobile onboarding,
  recorder screen with local + cloud engines, history, in-app test dictation.
- **MM2 — iOS keyboard + Action Button.** Extension target via the custom XcodeGen template, App
  Group handoff, swipe-back flow, `DictateIntent`. **First TestFlight build.**
- **MM3 — Android keyboard.** IME, recording, local + cloud, switch-back, onboarding.
  **First Play internal-testing build.**
- **MM4 — Store release.** App Store Connect app record (name availability check: "Murmur" may
  be taken; fallback "Murmur Dictation"), screenshots, privacy labels/policy, review notes with a
  demo Groq key, submission through the ASC API using the existing tooling in
  `~/arkhe-native-release-tools/`; Play listing, Data Safety, production rollout with the
  existing service account.

Deferred, deliberately: on-device whisper.cpp on mobile, a full QWERTY layout, streaming partial
transcripts, custom dictionary on mobile (lands with the desktop M3 dictionary work, which will
feed the `prompt` argument that already exists in the core API).

## 13. Toolchain to install on this Mac before MM0

`brew install xcodegen`; `rustup target add aarch64-apple-ios aarch64-apple-ios-sim
aarch64-linux-android x86_64-linux-android`; Android SDK + NDK through Android Studio's SDK
Manager (Android Studio is installed, no SDK yet); `cargo install uniffi-bindgen-cli` pinned to the
same version as the `uniffi` crate; `ANDROID_HOME`, `NDK_HOME`, and `JAVA_HOME`
(`/Applications/Android Studio.app/Contents/jbr/Contents/Home`) in the shell profile.
