# Murmur Mobile — iOS + Android Design

**Date:** 2026-09-03
**Status:** Approved by Matt 2026-09-03 after a second review pass. Both platforms, iOS first, fully native mobile apps on a shared Rust core, published under ARKHE Software, LLC (Apple team `X9PU63GUAN`).
**Builds on:** `docs/superpowers/specs/2026-06-27-murmur-dictation-app-design.md` (the macOS product) and `docs/HANDOFF.md` (current code).

## 1. Summary

Murmur today is a macOS menubar app: hold a key, speak, cleaned text pastes at the cursor.
This spec brings the same promise to iPhone and Android: **speak into any text field on your
phone, with as few taps as the platform allows, using the same engines and the same keys.**

The mobile product has three surfaces per platform:

| Surface | iOS | Android |
|---|---|---|
| Containing app (onboarding, engines, keys, history, settings) | Native SwiftUI app | Native Kotlin + Jetpack Compose app |
| Recording surface (where the mic actually runs) | Native SwiftUI screen inside the containing app | Native Kotlin view inside the keyboard itself |
| Text-insertion surface | Custom keyboard extension (voice-first) + Action Button App Intent | Custom keyboard (input method service, voice-first) |

Everything that turns audio into clean text — cloud STT, cleanup, provider config, WAV
encoding, resampling — is extracted from the Tauri crate into a **`murmur-core` Rust library**
and exposed to Swift and Kotlin through UniFFI. macOS keeps using the same crate. The React UI
stays desktop-only: the phone apps are native because every surface that matters on a phone
(recording, keyboard, input method, secure storage, permissions) has to be native anyway.

### Non-negotiables carried over from the product spec
- **Local-first and free by default.** On phones the free local engine is the platform's own
  on-device speech recognition (Apple `SpeechAnalyzer` / `SFSpeechRecognizer`, Android
  on-device `SpeechRecognizer`). No Murmur-managed model download, no signup.
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
4. **The phone apps are plain Xcode and Gradle projects, not Tauri-generated.** Tauri 2 can
   target iOS/Android, but the iOS round trip needs the app to open and be listening in well
   under a second, which a web view cold start works against, and the only thing Tauri would have
   reused is four settings screens. Decided with Matt on 2026-09-03.
5. **Keyboard extensions have roughly a 50–70 MB memory ceiling.** No model loading in the
   extension, ever. The extension only draws UI and inserts text.
6. **App Review guideline 4.4.1** (verified 2026-09-03 at developer.apple.com/app-store/review/guidelines)
   says keyboard extensions *must* "provide keyboard input functionality (e.g. typed characters)"
   and "remain functional without full network access and without requiring full access", and
   *must not* "launch other apps besides Settings". Consequences baked into this design:
   the iOS keyboard ships a real letter layout, typing works with Full Access off, and the mic
   button's launch of Murmur's own containing app is a **documented review risk**. Shipping
   dictation keyboards (Wispr Flow, Letterly, Typeless) use exactly this containing-app launch and
   are approved, and the review notes will say so, but the Action Button / Control Center path
   (§6.3) is designed as a first-class trigger that needs no keyboard launch at all, so the product
   still works if a reviewer objects.

## 3. Repository layout after this work

```
murmur/
  Cargo.toml                # workspace: crates/murmur-core + src-tauri
  crates/murmur-core/       # NEW: engines, providers, wav, resample, cleanup rules; UniFFI exports
  src-tauri/                # desktop app (macOS/Windows); behaviour unchanged; depends on murmur-core
  src/                      # React UI, desktop only (unchanged)
  apple/
    Murmur.xcodeproj        # targets: Murmur (app), MurmurKeyboard (extension), MurmurTests, MurmurKeyboardTests
    Murmur/                 # SwiftUI app: onboarding, home, settings, history, recorder, App Intents, Control widget
    MurmurKeyboard/         # keyboard extension (UIInputViewController + key layout)
    MurmurShared/           # Swift package: App Group handoff, Keychain wrapper, settings model, generated UniFFI bindings
    Frameworks/MurmurCore.xcframework   # build output (gitignored)
  android/
    settings.gradle.kts, app/   # one module: Compose app + MurmurInputMethodService; jniLibs + generated Kotlin binding
  scripts/build-core-mobile.sh  # cargo builds for the 4 mobile targets, uniffi-bindgen, xcframework + jniLibs
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
`apple/MurmurShared/Generated/` and `uniffi/murmur/core.kt` into `android/app/src/main/java/`.
An XCFramework (`MurmurCore.xcframework`, targets `aarch64-apple-ios` +
`aarch64-apple-ios-sim`) and an Android `.so` per ABI (`aarch64-linux-android`,
`x86_64-linux-android` for the emulator) are produced by `scripts/build-core-mobile.sh`.
These are build outputs, gitignored, and rebuilt by an Xcode Run Script phase and a Gradle
`buildRustCore` task (via `cargo-ndk`), so `xcodebuild` and `./gradlew` are the only entry points.

## 5. Containing apps (native)

Both apps have the same four screens and the same visual language as the desktop settings
window (`src/index.css` tokens: system font, indigo accent `#6366f1`, light/dark from the system).

| Screen | Content |
|---|---|
| **Onboarding** | Stepper, one step per screen, each with a single primary button; see order below. |
| **Home** | Big "Try dictation" button (runs the full pipeline into an on-screen field), keyboard/permission status chips with fix buttons, the last three dictations. |
| **History** | Reverse-chronological list, search, copy, delete (swipe), `source` chip (keyboard / action button / in-app). |
| **Settings** | Transcription engine (Local · Groq · OpenAI, with the same cost badges and "Get your API key ↗" + live verify as the desktop); Cleanup engine (Rules · Groq · OpenAI); toggles: auto-stop on silence, copy dictations to clipboard, Android only: auto-listen, return to previous keyboard; About. |

**Onboarding order**
1. Microphone (system prompt; deep link to Settings if denied).
2. Speech recognition (iOS only; the local engine needs it).
3. Engine: **Local (free, on-device)** preselected and needs nothing; Groq/OpenAI reuse the
   key flow. On iOS this step also calls `AssetInventory.reserve` for the locale.
4. Enable the keyboard: an illustrated step that deep-links to the platform keyboard settings
   (`app-settings:` / `ACTION_INPUT_METHOD_SETTINGS`) and polls until Murmur is enabled. iOS
   also asks for **Allow Full Access** with the honest one-line reason: "so the keyboard can
   read your dictation from Murmur and your keys."
5. iOS only, optional: **Action Button** (iPhone 15 Pro and newer) or **Control Center button**
   (every iPhone on iOS 18+), each with a deep link and a "Test it" button.
6. Test dictation on the Home screen.

**iOS app (`apple/Murmur`, SwiftUI, min iOS 17).** State lives in observable view models so
the logic is unit-testable without UI. Settings are stored in `UserDefaults(suiteName:
"group.com.murmur.app")` so the keyboard can read the engine choice; keys live in the Keychain
under access group `$(TeamIdentifierPrefix)com.murmur.app` shared with the extension. History
is SQLite (GRDB) in the App Group container. Keyboard-enabled detection reads
`UserDefaults.standard` key `AppleKeyboards` for the extension bundle id; Full Access is known
because the extension writes a `fullAccess` heartbeat (`hasFullAccess`) to the App Group each
time it appears.

**Android app (`android/app`, Kotlin + Jetpack Compose, min SDK 28).** Settings in DataStore,
keys in `EncryptedSharedPreferences`, history in Room. The input method service lives in the
same module and process, so it reads the same stores directly. `RECORD_AUDIO` is requested
here (an IME cannot show a runtime permission dialog itself). Keyboard-enabled detection uses
`InputMethodManager.enabledInputMethodList`.

## 6. iOS: keyboard extension + recording round trip

### 6.1 Keyboard (`MurmurKeyboard`, `UIInputViewController`, Swift)
A real keyboard with dictation as its headline key, because guideline 4.4.1 requires typed-character
input and because users should never have to switch keyboards to fix one word.

Layout, top to bottom, standard system keyboard height, system light/dark, indigo accent:
- A status strip in place of the suggestions bar: "Tap the mic to dictate" · while a result is
  pending: the transcript preview with **Insert** (in case auto-insert did not fire) and **Discard**.
- Three QWERTY rows with shift, a `123` page (numbers and common symbols) and a `#+=` page,
  delete. Key caps use the system key look so it reads as an iPhone keyboard, not a web widget.
- Bottom row: `123`, globe (next keyboard), **mic** (left of space, where the system dictation
  key lives, so muscle memory carries over), space, return.
- No autocorrect, predictions, emoji page, or settings inside the keyboard in v1. The platform
  still auto-switches to the system keyboard for number, phone, decimal, and email fields.

Full Access off: every key types normally; the mic key shows a one-line explainer and a
**Settings** button (launching Settings is allowed), nothing else changes.

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
Presented the instant the `murmur://dictate` URL arrives (`onOpenURL`), as a full-screen cover
over whatever screen the app was on; the app's launch path does no work before this so the mic
is live within ~300 ms of foreground.
- Starts recording immediately (AVAudioEngine, 16 kHz mono float).
- Shows the same visual language as the Mac HUD: pulsing red dot while recording, translucent
  squiggle while transcribing. A live level meter drives the dot.
- Stops on: tap anywhere, 1.5 s of silence after speech (auto-stop, on by default, toggle in
  settings), or 120 s hard cap.
- Pipeline: platform speech (`SpeechAnalyzer` on iOS 26+, `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition = true` on iOS 17–25; both consume the same `AVAudioPCMBuffer`
  tap, so one capture path feeds local and cloud) **or** `murmur-core.transcribe_cloud`
  when the engine is Groq/OpenAI → `murmur-core.clean_text` → history row → `result` to the
  App Group **and** to the clipboard.
- Final state: the cleaned text in a card, a copy confirmation, and the line **"Swipe back to
  your app — the text will be inserted."** with an 8 s auto-dismiss of the sheet. No attempt is
  made to switch apps programmatically (constraint 2).
- Errors follow the Mac rules: cloud failure falls back to local speech, then to rule cleanup;
  an empty transcript shows "Didn't catch that" and inserts nothing.
- `SpeechAnalyzer` language assets are system-managed downloads shared with system Dictation
  (usually already present). Onboarding calls `AssetInventory.reserve` for the user's locale so
  the first dictation is never blocked behind a download; if assets are missing, the recorder
  uses `SFSpeechRecognizer` on-device for that dictation.

### 6.3 Action Button / Shortcuts (`DictateIntent`, App Intents)
- `AppShortcutsProvider` exposes **"Dictate with Murmur"** (`openAppWhenRun = true`), so it can
  be bound to the Action Button, Back Tap, or Siri. A `ControlWidget` (iOS 18+) exposes the same
  intent as a Control Center button and a Lock Screen control, so every iPhone gets a one-press
  trigger even without an Action Button. None of these launch from the keyboard, so none touch
  guideline 4.4.1.
- It opens the same recording screen with `source = action-button`. Delivery: clipboard always;
  App Group `result` with `session = "intent"` so the Murmur keyboard, if active in the host app,
  inserts it on return. Otherwise the user pastes.

### 6.4 Project wiring
- `apple/Murmur.xcodeproj` is hand-maintained. Target `MurmurKeyboard` is an app extension
  (`NSExtensionPointIdentifier = com.apple.keyboard-service`, `RequestsOpenAccess = YES`,
  `PrimaryLanguage = en-US`), links `MurmurShared` and `MurmurCore.xcframework`. Both targets
  carry the App Group and Keychain access group entitlements. Bundle ids: `com.murmur.app`
  (app), `com.murmur.app.keyboard` (extension). A Run Script phase on the app target runs
  `scripts/build-core-mobile.sh ios` so a plain `xcodebuild` produces the framework.
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
- `RECORD_AUDIO` is granted in the containing app during onboarding; if missing, the view shows
  "Open Murmur to allow the microphone" with a launch button.
- **Local engine:** Android's `SpeechRecognizer` records from the mic itself and does not accept a
  PCM buffer, so the IME hands it the session directly:
  `SpeechRecognizer.createOnDeviceSpeechRecognizer` (API 31+; `createSpeechRecognizer` with
  `EXTRA_PREFER_OFFLINE` on API 28–30). Partial results stream into the strip, which gives a live
  preview for free. If the device has no offline model: cloud if a key exists, else "Download
  offline speech in Google settings" with a deep link.
- **Cloud engine:** the IME records with `AudioRecord` (16 kHz mono PCM) and calls
  `murmur-core` cloud STT.
- Stop: tap, 1.5 s silence, or 120 s cap. Then `clean_text` → `currentInputConnection.commitText`
  → history row.
- After commit: if **Return to previous keyboard** is on (default on), call
  `switchToPreviousInputMethod()`; when there is no previous IME (Murmur was picked from Settings)
  fall back to `switchToNextInputMethod(false)`. The whole round trip is: globe, speak, done.
- Android v1 has no letter keys on purpose: it returns to Gboard automatically, and Play has no
  typed-input rule. Parity with the iOS letter layout is a follow-up if users ask for it.
- The main app's cleanup/engine settings and secrets are shared because the IME runs in the app's
  own process and sandbox.

### 7.2 Containing app wiring
- The IME lives in the single `app` module under `com.murmur.app.ime`, registered in the
  manifest next to the main activity.
- A Gradle task `buildRustCore` runs `scripts/build-core-mobile.sh android`, which uses
  `cargo-ndk` to build `libmurmur_core.so` per ABI into `jniLibs` and drops the UniFFI Kotlin
  binding into the source set. `./gradlew assembleDebug` is the only entry point.
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
| Result never picked up (user never swiped back) | Text stays on the clipboard (if the copy setting is on) and in history; `pending` expires after 10 minutes so it can't insert later. |
| App killed mid-recording | Recorder writes samples to a temp file every 2 s; on next launch offers "Finish last dictation". |
| Android no offline speech model | Deep link to Google speech settings; cloud if configured. |

## 10. Security & privacy

- Keys: iOS Keychain access group / Android `EncryptedSharedPreferences`, never in
  `settings.json`, never in the App Group defaults, never logged.
- The App Group `result` holds dictated text only until inserted or for 10 minutes.
- **Copy dictations to the clipboard** is a setting, default on, because it is the safety net for
  the round trip. The onboarding line under it says plainly that Universal Clipboard will sync
  those dictations to the user's other Apple devices; turning it off keeps text in Murmur only.
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
  source, the keyboard's Full-Access-off rendering, and the key layout (every page inserts the
  character it shows, shift/caps behave like the system keyboard).
- **Kotlin (JUnit + Robolectric):** the IME state machine, `commitText` + switch-back ordering
  with a fake `InputConnection`, and silence detection.
- **Swift view models (XCTest):** onboarding step gating, engine/key state, history search.
- **React (Vitest):** the desktop UI is untouched; the existing 24 tests keep passing.
- **CI:** the existing matrix adds `cargo build --target aarch64-apple-ios` and
  `--target aarch64-linux-android` for `murmur-core`, `xcodebuild test` on the simulator for
  both Swift test targets, and `./gradlew testDebugUnitTest`.
- **Device gates (only Matt):** mic prompts, Full Access, real keyboard insertion into Messages,
  Safari, and Notes; Action Button; swipe-back timing; Gboard round trip on a physical Android
  device or emulator with Google speech services.

## 12. Milestones

Each milestone gets its own implementation plan and lands on `main` behind a green CI.

- **MM0 — Core extraction + shells.** `murmur-core` workspace crate, UniFFI bindings,
  `build-core-mobile.sh`, an iOS app shell and an Android app shell that boot on simulator and
  emulator and call one core function end to end. Desktop unchanged, all existing tests green.
- **MM1 — iOS containing app.** Keychain/App Group/settings model, onboarding, home, settings,
  history, the recorder screen with local + cloud engines, in-app test dictation.
- **MM2 — iOS keyboard + Action Button.** Extension target, the letter/number/symbol layout, App Group handoff, swipe-back flow, `DictateIntent` + Control
  Center control. **First TestFlight build.**
- **MM3 — Android app + keyboard.** Compose onboarding/home/settings/history, the IME with
  recording, local + cloud, switch-back. **First Play internal-testing build.**
- **MM4 — Store release.** App Store Connect app record (name availability check: "Murmur" may
  be taken; fallback "Murmur Dictation"), screenshots, privacy labels/policy, review notes with a
  demo Groq key, submission through the ASC API using the existing tooling in
  `~/arkhe-native-release-tools/`; Play listing, Data Safety, production rollout with the
  existing service account.

Deferred, deliberately: on-device whisper.cpp on mobile, autocorrect and predictions in the iOS
keyboard, letter keys on Android, streaming partial transcripts on iOS, custom dictionary on mobile (lands with the desktop M3 dictionary work, which will
feed the `prompt` argument that already exists in the core API).

## 13. Toolchain to install on this Mac before MM0

`rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-linux-android
x86_64-linux-android`; `cargo install cargo-ndk`; `cargo install uniffi-bindgen-cli` pinned to
the same version as the `uniffi` crate; Android SDK (API 35) + NDK + an emulator image through
Android Studio's SDK Manager (Android Studio is installed, no SDK yet); `ANDROID_HOME`,
`ANDROID_NDK_HOME`, and `JAVA_HOME` (`/Applications/Android Studio.app/Contents/jbr/Contents/Home`)
in the shell profile. Xcode 26.6 is already installed and the ARKHE team's development
certificate is in the keychain; the `com.murmur.app` identifiers, App Group, and keyboard
entitlement are registered in that team's developer portal during MM2.
