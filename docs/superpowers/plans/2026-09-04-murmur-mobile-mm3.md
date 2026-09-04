# Murmur Mobile MM3 — Android app + voice keyboard

**Goal:** Turn the MM0 Android shell into the real thing: a Compose app (onboarding, home, settings, history) and the Murmur input method — a voice keyboard that records itself, transcribes (Android on-device speech or a cloud engine through `murmur-core`), cleans, commits the text into whatever field is focused, and returns to the previous keyboard. First Play internal-testing build at the end.

**Spec:** `docs/superpowers/specs/2026-09-03-murmur-mobile-design.md` §2 (constraint 3), §5 (Android paragraph + onboarding), §7 (all), §8 (Android path), §9, §10, §11, §12. MM1's plan is the iOS twin — the Kotlin types below mirror its Swift ones on purpose so the two apps stay easy to reason about together.

**Branch / worktree:** new worktree `~/murmur-wt/mobile-mm3` on branch `feat/mobile-mm3` from the latest mobile branch. Never touch `~/murmur`.

**Model split:** Opus implements one task per subagent; Fable reviews each diff.

## Global constraints (from the spec)

- Package `com.murmur.app`, min SDK 28, target/compile SDK 35, Kotlin 2.1, Compose (Material3), single `:app` module. The IME lives in `com.murmur.app.ime` in the same module and process.
- Keys live in `EncryptedSharedPreferences` only; never in DataStore, logs, Room, or Compose state longer than a call needs them.
- Local engine = Android on-device `SpeechRecognizer` (`createOnDeviceSpeechRecognizer` on API 31+, `createSpeechRecognizer` + `EXTRA_PREFER_OFFLINE` on 28–30). It records from the mic itself; it does not accept a buffer. Cloud engine = `AudioRecord` 16 kHz mono → `murmur-core` `transcribeCloud`. Cleanup = `murmur-core` `cleanText` (rules fallback inside the core).
- Every transcript is written to history **before** it is committed. Empty → nothing committed, "Didn't catch that."
- `RECORD_AUDIO` is requested by the app (an IME cannot show the runtime dialog); the IME shows "Open Murmur to allow the microphone" with a launch button when it is missing.
- Auto-listen (start recording when the keyboard appears) and Return-to-previous-keyboard are both **on by default**; the whole round trip is globe → speak → done.
- Visual language: indigo `0xFF6366F1`, Material3 with dynamic colour off (fixed palette matching the desktop's light/dark tokens), system fonts. Keyboard height ~220 dp.
- Logic in plain Kotlin classes / `ViewModel`s with injected fakes; JVM unit tests (JUnit 4 + kotlinx-coroutines-test) for everything that doesn't need Android; Robolectric for Room/DataStore/SpeechRecognizer-adjacent code. No test touches the mic, the network, or Google speech services.
- Generated Kotlin binding (`app.murmur.core`) and `jniLibs` stay gitignored; `./gradlew` remains the only entry point (`buildRustCore` runs the script).

## Verification gate

```bash
cd ~/murmur-wt/mobile-mm3 && . "$HOME/.cargo/env"
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"; export ANDROID_HOME="$HOME/Library/Android/sdk"
scripts/build-core-mobile.sh android
cd android && ./gradlew --no-daemon assembleDebug testDebugUnitTest lintDebug
```
Plus the emulator run in Task 5 and the device gates in Task 6.

---

## Task 1 ✅ `273f25d` — Foundations: settings, secrets, history, pipeline

**Files (create), all under `android/app/src/main/java/com/murmur/app/`:** `data/Settings.kt`, `data/SettingsStore.kt` (DataStore Preferences), `data/SecretStore.kt` (`interface SecretStore`, `EncryptedSecretStore`, `InMemorySecretStore`), `data/history/TranscriptEntity.kt`, `data/history/TranscriptDao.kt`, `data/history/HistoryDatabase.kt`, `data/history/HistoryStore.kt`, `engine/SpeechEngine.kt` (interface + `PipelineError`), `engine/DictationPipeline.kt`, `di/AppGraph.kt` (a hand-rolled singleton graph — no Hilt).
**Tests:** `android/app/src/test/java/com/murmur/app/{SettingsStoreTest,SecretStoreTest,HistoryStoreTest,DictationPipelineTest}.kt` (Robolectric for the two that touch Room/DataStore).
**Modify:** `android/app/build.gradle.kts` — add `androidx.datastore:datastore-preferences`, `androidx.security:security-crypto` (1.1.0-alpha06 or newer stable), Room (`room-runtime`, `room-ktx`, `ksp` `room-compiler` — add the KSP plugin), `androidx.lifecycle:lifecycle-viewmodel-compose`, `androidx.navigation:navigation-compose`, test deps `robolectric`, `kotlinx-coroutines-test`, `androidx.test:core`, `androidx.room:room-testing`.

**Produces:**
```kotlin
enum class SttEngine(val id: String) { LOCAL("local"), GROQ("groq"), OPENAI("openai") }
enum class CleanupEngine(val id: String) { RULE("rule"), GROQ("groq"), OPENAI("openai") }
enum class ProviderId(val id: String, val keychainAccount: String, val core: app.murmur.core.Provider, val displayName: String, val costLabel: String, val signupSteps: List<String>) { GROQ(...), OPENAI(...) }   // copy from src/components/EngineSettings.tsx PROVIDER_INFO verbatim
data class Settings(val stt: SttEngine = SttEngine.LOCAL, val cleanup: CleanupEngine = CleanupEngine.RULE, val autoStopOnSilence: Boolean = true, val copyToClipboard: Boolean = false /* Android default OFF: commitText is direct, the clipboard is not the safety net here */, val autoListen: Boolean = true, val returnToPreviousKeyboard: Boolean = true, val onboardingComplete: Boolean = false)
class SettingsStore(private val dataStore: DataStore<Preferences>) { val settings: Flow<Settings>; suspend fun current(): Settings; suspend fun update(change: (Settings) -> Settings) }
interface SecretStore { fun get(account: String): String?; fun set(account: String, value: String); fun delete(account: String) }
class EncryptedSecretStore(context: Context) : SecretStore   // EncryptedSharedPreferences "murmur.secrets", MasterKey AES256_GCM
class InMemorySecretStore : SecretStore
enum class TranscriptSource(val id: String) { IN_APP("in-app"), KEYBOARD("keyboard") }
@Entity(tableName = "transcripts") data class TranscriptEntity(@PrimaryKey(autoGenerate = true) val id: Long = 0, @ColumnInfo(name = "raw_text") val rawText: String, @ColumnInfo(name = "clean_text") val cleanText: String, val source: String, @ColumnInfo(name = "created_at") val createdAt: Long)
class HistoryStore(private val dao: TranscriptDao) { suspend fun insert(t: TranscriptEntity): TranscriptEntity; suspend fun list(limit: Int = 50, query: String? = null): List<TranscriptEntity>; suspend fun delete(id: Long); suspend fun recent(n: Int): List<TranscriptEntity>; fun observeRecent(n: Int): Flow<List<TranscriptEntity>> }
interface SpeechEngine { suspend fun transcribe(session: AudioSession, partial: (String) -> Unit): String }
sealed class PipelineError(message: String) : Exception(message) { object MicDenied; object NoSpeechEngine; class Cloud(message: String); object Empty }
data class PipelineOutcome(val transcript: TranscriptEntity, val usedCloudStt: Boolean, val usedCloudCleanup: Boolean)
class DictationPipeline(settings: SettingsStore, secrets: SecretStore, history: HistoryStore, localEngine: () -> SpeechEngine, cloudEngine: (CloudConfig) -> SpeechEngine, clean: suspend (String, CloudConfig?) -> CleanResult = ::cleanText) {
    suspend fun run(session: AudioSession, source: TranscriptSource, partial: (String) -> Unit): PipelineOutcome
    // same five rules as iOS: cloud needs a key else local; cloud failure → local retry (the session can be replayed — see Task 2); empty → PipelineError.Empty; cleanup config only when cleanup != RULE; history insert before return
}
```
`AudioSession` is defined in Task 2 but referenced here; declare the interface in `engine/AudioSession.kt` in this task: `interface AudioSession { val levels: Flow<Float>; suspend fun samples16kMono(): FloatArray /* completes when stopped */; fun stop() }` plus a `ReplayableAudioSession` wrapper so the cloud→local retry can hand the same audio to the local engine — **except** the on-device `SpeechRecognizer` cannot take a buffer, so on Android the retry rule is: cloud failure → if the device has an offline recognizer, tell the user "Cloud failed — tap to try on device" (the IME re-listens) rather than silently replaying; record that in the outcome as `PipelineError.Cloud`. Document this iOS/Android difference in `DictationPipeline.kt`.

**Tests:** settings default + round trip through DataStore (Robolectric, temp file); secret store round trip on `InMemorySecretStore` and Robolectric `EncryptedSecretStore`; history insert/list/search/delete/recent (in-memory Room); pipeline rules with fake engines (local path, cloud path with key, missing key → local, empty → `Empty` and no row, cleanup config gating, history written before return).

**Commit:** `feat(android): settings, secrets, Room history, and dictation pipeline`.

---

## Task 2 ✅ `586ae4d` — Audio: recorder, silence detector, local + cloud engines, permissions

**Files (create):** `audio/AudioRecorder.kt` (`AudioRecord`, `MediaRecorder.AudioSource.VOICE_RECOGNITION`, 16 kHz mono PCM16 → Float, RMS levels), `audio/SilenceDetector.kt` (pure; same constants as iOS: threshold 0.015, hangover 1.5 s, minSpeech 0.4 s), `engine/LocalSpeechEngine.kt`, `engine/CloudSpeechEngine.kt`, `engine/SpeechEngines.kt` (`local(context)`, `cloud(cfg)`, `isLocalAvailable(context)`: `SpeechRecognizer.isOnDeviceRecognitionAvailable` on 31+, else `isRecognitionAvailable`), `Permissions.kt` (`hasRecordAudio`, `openAppSettings`).
**Tests:** `SilenceDetectorTest` (same three cases as iOS), `CloudSpeechEngineTest` (fake core call receives the concatenated samples), `LocalSpeechEngineTest` (Robolectric: a fake `SpeechRecognizer` is not feasible — test the result/partial/error mapping through the engine's `RecognitionListener` implementation directly by invoking its callbacks: `onPartialResults` → partial, `onResults` → return, `ERROR_NO_MATCH`/`ERROR_SPEECH_TIMEOUT` → `""`, other errors → `PipelineError.NoSpeechEngine` or a message).

**Behaviour:** `LocalSpeechEngine` starts its own listening (`startListening` with `RecognizerIntent.ACTION_RECOGNIZE_SPEECH`, `EXTRA_PARTIAL_RESULTS true`, `EXTRA_LANGUAGE_MODEL LANGUAGE_MODEL_FREE_FORM`, `EXTRA_PREFER_OFFLINE true`, `EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS 1500` when auto-stop is on); its `AudioSession` argument is only used for `stop()` (calling `stopListening`) and for the level meter via `onRmsChanged` (mapped from dB to 0..1). `CloudSpeechEngine` drives `AudioRecorder` through the `AudioSession`, awaits `samples16kMono()`, calls `transcribeCloud`. `AudioRecorder` implements `AudioSession`; the IME picks which engine owns the mic per dictation, so only one thing ever records.

**Commit:** `feat(android): AudioRecord capture, silence detection, on-device + cloud speech engines`.

---

## Task 3 ✅ `8605789` — The input method

**Files (create):** `ime/MurmurInputMethodService.kt`, `ime/ImeController.kt`, `ime/ImeView.kt` (Compose), `ime/ComposeInputView.kt` (an `AbstractComposeView` subclass that installs `LifecycleOwner`/`ViewModelStoreOwner`/`SavedStateRegistryOwner` on the view tree — required for Compose inside an `InputMethodService`; implement the three owners on the service), `res/xml/method.xml`, `res/values/strings.xml` additions.
**Modify:** `AndroidManifest.xml` — `<service android:name=".ime.MurmurInputMethodService" android:permission="android.permission.BIND_INPUT_METHOD" android:exported="true" android:label="@string/ime_label"> <intent-filter><action android:name="android.view.InputMethod"/></intent-filter> <meta-data android:name="android.view.im" android:resource="@xml/method"/> </service>`; `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`. `method.xml`: `<input-method android:settingsActivity="com.murmur.app.MainActivity" android:supportsSwitchingToNextInputMethod="true" android:isDefault="false"/>`.
**Tests:** `ImeControllerTest` (fakes for pipeline, permissions, input connection, clock).

**Produces:**
```kotlin
sealed interface ImePhase { object Idle; object NeedsPermission; data class Listening(val level: Float, val elapsedMs: Long); data class Transcribing(val partial: String); data class Done(val clean: String); data class Failed(val message: String, val canRetryOnDevice: Boolean) }
interface TextSink { fun commit(text: String); fun deleteBackward(); fun contextBefore(): String? }
interface ImeHost { fun switchToPrevious(); fun switchToNext(); fun openApp(); val needsInputModeSwitch: Boolean }
class ImeController(settings: SettingsStore, pipeline: DictationPipeline, sessionFactory: () -> AudioSession, permissions: () -> Boolean, clock: () -> Long = System::currentTimeMillis, scope: CoroutineScope, maxDurationMs: Long = 120_000) {
    val phase: StateFlow<ImePhase>
    fun onShown(host: ImeHost, sink: TextSink)   // permissions() false → NeedsPermission; else if settings.autoListen → startListening()
    fun startListening(); fun stop()             // stop = user tap / silence / cap → pipeline runs → Done → sink.commit(clean + " " if contextBefore doesn't end in whitespace/newline ... keep simple: commit clean followed by a single space) → if settings.returnToPreviousKeyboard → host.switchToPrevious() after 400 ms; Failed(Empty) → "Didn't catch that." and stays on the keyboard
    fun retryOnDevice()                          // after a cloud failure
    fun tapGlobe(); fun tapDelete(); fun tapSpace(); fun tapReturn()
}
```
`MurmurInputMethodService`: `onCreateInputView()` returns the `ComposeInputView` rendering `ImeView(controller)`; `onStartInputView` → `controller.onShown(host = this, sink = InputConnectionSink(currentInputConnection))`; `onFinishInputView` → `controller.stop()` without committing; `switchToPrevious()` = `switchToPreviousInputMethod()` falling back to `switchToNextInputMethod(false)`; `openApp()` launches `MainActivity` with `FLAG_ACTIVITY_NEW_TASK` and an extra `EXTRA_REQUEST_MIC = true`. Height 220 dp. `ImeView`: status strip (phase text / partial / error + **Try on device** when `canRetryOnDevice`), a big indigo mic button (pulses with `level` while listening; tap to stop), and a bottom row: globe (only when `needsInputModeSwitch`), delete, space, return. No letter keys (spec §7.1).

**Tests (`ImeControllerTest`):** no permission → `NeedsPermission`, nothing recorded; auto-listen starts on show; stop → pipeline → commit once with trailing space → `switchToPrevious` called when the setting is on and not when off; empty → Failed with the copy and no commit; cloud failure with offline available → `Failed(canRetryOnDevice = true)` → `retryOnDevice()` runs local; cap fires at 120 s with the injected clock; delete/space/return go to the sink.

**Commit:** `feat(android): Murmur voice input method`.

---

## Task 4 ✅ `3bccb99` — App screens: onboarding, home, settings, history

**Files (create):** `ui/RootNav.kt` (NavHost: onboarding until `onboardingComplete`, then bottom nav Home · History · Settings), `ui/theme/MurmurTheme.kt`, `ui/onboarding/{OnboardingViewModel,OnboardingScreen}.kt`, `ui/home/{HomeViewModel,HomeScreen}.kt` (replaces the MM0 shell), `ui/settings/{EngineSettingsViewModel,SettingsScreen,ProviderKeySection}.kt`, `ui/history/{HistoryViewModel,HistoryScreen}.kt`, `ui/components/{StatusChip,Card}.kt`, `KeyboardStatus.kt` (`isEnabled(context)` via `InputMethodManager.enabledInputMethodList` matching our service; `openImeSettings(context)` = `ACTION_INPUT_METHOD_SETTINGS`; `showImePicker(context)` = `InputMethodManager.showInputMethodPicker()`), `ui/recorder/{RecorderViewModel,RecorderScreen}.kt` (the in-app "Try dictation" — same phases as the IME controller but committing into an on-screen `TextField`; reuse `ImeController` with a `TextSink` backed by Compose state).
**Modify:** `MainActivity.kt` (handles `EXTRA_REQUEST_MIC` by jumping to the mic permission step), delete `HomeScreen.kt`'s MM0 body, keep `formatCleaned` test or replace it.
**Tests:** `OnboardingViewModelTest` (steps: mic → engine → keyboard → test; gating: mic granted, engine ready = local available or key verified, keyboard enabled), `EngineSettingsViewModelTest` (saveKey trims + verifies → Connected; rejected → Failed(message), key kept; removeKey; `providersInUse` order), `HistoryViewModelTest` (search/delete), `KeyboardStatusTest` (Robolectric with a shadow `InputMethodManager` list).

Copy is the desktop's, verbatim, as on iOS. Settings toggles: "Start listening when the keyboard opens" (`autoListen`), "Return to your keyboard after dictating" (`returnToPreviousKeyboard`), "Stop automatically when you pause" (`autoStopOnSilence`), "Copy dictations to the clipboard" (`copyToClipboard`, default off on Android). Onboarding step 3 (keyboard): **Open keyboard settings** → returns → polls `KeyboardStatus.isEnabled` every 1 s; then **Try it**: opens a `TextField`, calls `showImePicker` so the user picks Murmur once, and the first dictation lands in that field.

**Commit:** `feat(android): onboarding, home, settings, history, and in-app dictation`.

---

## Task 5 ✅ `ea14c2f` — Emulator run-through + Play internal-testing build

**Files (create):** `scripts/android-play-upload.sh` (bash: `./gradlew bundleRelease` then `node scripts/play-upload.mjs --aab android/app/build/outputs/bundle/release/app-release.aab --package com.murmur.app --track internal --status completed`), `scripts/play-upload.mjs` (adapted from `~/sober-navigator-appstore/scripts/play-upload.mjs` — same Google Play Developer API v3 edits flow with `googleapis`, parameterised by `--package`; service account JSON path from `PLAY_SERVICE_ACCOUNT` env, default `~/arkhe-android-signing/play-service-account.json`; never commit a key), `android/keystore.properties.example`, `android/README.md` (release section).
**Modify:** `android/app/build.gradle.kts` — `signingConfigs.release` reading `android/keystore.properties` (gitignored: `storeFile`, `storePassword`, `keyAlias`, `keyPassword`), `buildTypes.release { isMinifyEnabled = true; proguard rules keeping JNA + `app.murmur.core` }`, `versionCode` from `MURMUR_VERSION_CODE` env (default 1), `versionName "0.1.0"`; add `android/app/proguard-rules.pro`.

**Emulator run-through (implementer, with `murmur35` AVD):** install debug, complete onboarding with Local engine (the Google APIs image has offline speech for en-US; if not, use the `adb shell` settings trick to enable, else use a Groq key from an env var **never echoed**), enable the IME via `adb shell ime enable com.murmur.app/.ime.MurmurInputMethodService`, open Messages/a `TextField` in the app, `adb shell ime set …`, `adb shell input keyevent` cannot speak — so play a WAV into the emulator mic (`emulator -avd murmur35 -mic-input file.wav` is not available; instead use `adb shell settings` + the emulator console `event send`? Not workable) — **so the emulator verifies the UI states, the permission flow, the IME appearing and switching back, and the cloud path with a pre-recorded 16 kHz sample injected through a debug-only `FakeAudioSession` behind `BuildConfig.DEBUG` + an intent extra**; real-mic dictation is Task 6's device gate. Screenshots to the scratchpad: onboarding, IME idle, IME listening, IME done + switched back.

**[MATT] before the upload can succeed:**
1. Play Console → **Create app**: name Murmur (or Murmur Dictation), default language English (US), app, free; package name is fixed by the first upload.
2. Generate the upload keystore once: `keytool -genkeypair -v -keystore ~/murmur-android-signing/murmur-upload.jks -alias murmur -keyalg RSA -keysize 2048 -validity 10000` and fill `android/keystore.properties`. Keep the `.jks` + passwords in the password manager; Play App Signing holds the app signing key.
3. Play Console → Users and permissions → grant the existing service account (the one in `play-service-account.json`) access to the Murmur app (Release manager).
4. Complete the store-listing minimums for internal testing (app name, short/full description placeholders are fine, privacy policy URL, Data Safety form: microphone audio processed on device or sent to the user's chosen provider, not collected by Murmur).

**Commit:** `build(android): release signing, Play internal-testing upload script`.

---

## Task 6 ✅ (docs landed; device gates + Play app record pending Matt) — Device gates + docs

**Files (modify):** `android/README.md`, `docs/HANDOFF.md` (MM3 section), this plan (tick tasks).

**Device gates (Matt, physical Android phone with USB debugging, or the emulator for everything but real speech):**
1. Fresh install → onboarding: mic prompt grants; Local engine ready (or the Google offline pack downloads); keyboard settings open and Murmur appears; enabling it flips the check.
2. In Messages: tap the field → globe/keyboard switcher → Murmur → it starts listening immediately → speak → auto-stops → text is committed with a trailing space → Gboard is back within half a second.
3. Turn off auto-listen and return-to-keyboard in Settings → the keyboard waits for the mic tap and stays after committing; the globe returns to Gboard.
4. Settings → Groq key: "Get your API key ↗" opens the browser; paste → "✓ Connected"; STT = Groq → dictation works; airplane mode → "Try on device" appears and works.
5. Revoke the mic permission in system settings → the keyboard shows "Open Murmur to allow the microphone" → the button opens the app at the mic step.
6. Rotate the phone while listening — the keyboard survives and the dictation completes.

**Commit:** `docs(android): MM3 handoff and device checklist`.

---

## Review checklist (Fable, after each task)
1. No key value reaches `Log.*`, `println`, DataStore, Room, or Compose state beyond the call that needs it (`grep -rn "apiKey" android/app/src/main` shows only `EncryptedSecretStore`, `EngineSettingsViewModel`, `DictationPipeline`, `CloudSpeechEngine`).
2. Only one component records at a time: the IME's `sessionFactory` hands the mic to exactly one engine per dictation; the app's recorder and the IME never run together.
3. `commit` happens after `HistoryStore.insert` (pipeline test + controller test both assert order).
4. `./gradlew lintDebug` has no new errors; `testDebugUnitTest` green; the build still runs `buildRustCore` first.
5. Signatures match this plan's **Produces** blocks.
