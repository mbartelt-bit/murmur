# Murmur — Android app shell

A single Compose module (`:app`, package `com.murmur.app`) that calls the shared Rust
crate `crates/murmur-core` through its UniFFI Kotlin bindings. Min SDK 28, target/compile
SDK 35.

## Prerequisites

- **JDK 17+** — Android Studio ships one:
  `export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"`
- **Android SDK** with platform 35, build-tools 35.0.0 and NDK `27.2.12479018`.
  Gradle finds it via `local.properties` (`sdk.dir=…`, gitignored) or the `ANDROID_HOME`
  environment variable — either one works, so a fresh clone can just
  `export ANDROID_HOME="$HOME/Library/Android/sdk"` instead of writing the file.
- **Rust + `cargo-ndk` on `PATH`** (`. "$HOME/.cargo/env"`). The `buildRustCore` Gradle task
  shells out to `../scripts/build-core-mobile.sh android` from the repo root before every
  compile, so `./gradlew` is the only entry point — there is no separate Rust step to
  remember. It produces (both gitignored):
  - `app/src/main/jniLibs/{arm64-v8a,x86_64}/libmurmur_core.so`
  - `app/src/main/java/app/murmur/core/murmur_core.kt`

## Commands

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
. "$HOME/.cargo/env"

cd android
./gradlew assembleDebug        # builds the Rust core, then the debug APK
./gradlew testDebugUnitTest    # JVM unit tests (pure Kotlin only — no .so on the JVM)
```

### Run it on the emulator

The FFI itself can only be verified on a device/emulator, because a JVM unit test cannot
load `libmurmur_core.so`.

```bash
# once: avdmanager create avd -n murmur35 -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_7
"$ANDROID_HOME/emulator/emulator" -avd murmur35 -no-window -no-audio -no-boot-anim &
until [ "$("$ANDROID_HOME/platform-tools/adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 5; done

./gradlew installDebug
"$ANDROID_HOME/platform-tools/adb" shell am start -n com.murmur.app/.MainActivity
"$ANDROID_HOME/platform-tools/adb" exec-out screencap -p > /tmp/android-shell.png

"$ANDROID_HOME/platform-tools/adb" emu kill
```

Debug builds accept `--es murmurScreen home|history|settings|onboarding|recorder` on that
`am start`, which lands on one screen (and seeds two history rows the first time) so a
screenshot pass does not have to drive the UI. A release build ignores it.

## Layout

| Path | What |
|---|---|
| `app/src/main/java/com/murmur/app/MainActivity.kt` | Compose host activity |
| `app/src/main/java/com/murmur/app/ui/` | The app's screens: onboarding, home, history, settings, in-app dictation |
| `app/src/main/java/com/murmur/app/ime/` | The Murmur voice keyboard |
| `app/src/main/java/com/murmur/app/{data,engine,audio}/` | Settings, secrets, history, and the dictation pipeline |
| `app/src/main/java/app/murmur/core/` | Generated UniFFI bindings (build output, gitignored) |
| `app/src/main/jniLibs/` | `libmurmur_core.so` per ABI (build output, gitignored) |

## Release build

```bash
./gradlew bundleRelease      # app/build/outputs/bundle/release/app-release.aab
./gradlew assembleRelease    # the same, as an APK
```

Release is minified: R8 shrinks the code and the resources, and `app/proguard-rules.pro`
keeps the two things it cannot see — JNA's reflection into `libmurmur_core.so` (the whole
`app.murmur.core` package, which is generated and so cannot be annotated) and the input
method, which the system resolves by name. After a change to the rules, check
`app/build/outputs/mapping/release/` : `seeds.txt` should list ~740 `app.murmur.core`
entries and `mapping.txt` should map them to themselves.

Signing reads `android/keystore.properties`, which is gitignored — copy
`keystore.properties.example` and fill it in. **Without that file the bundle still builds,
unsigned**, so a fresh clone and CI can verify the release path; Gradle prints a warning
saying the .aab cannot be uploaded.

## Play (internal testing)

One-time, in the Play Console (Matt):

1. **Create app**: name Murmur (or Murmur Dictation), English (US), app, free. The package
   `com.murmur.app` is fixed by the first upload.
2. Create the upload keystore once and keep it out of the repo:
   ```bash
   mkdir -p ~/murmur-android-signing
   keytool -genkeypair -v -keystore ~/murmur-android-signing/murmur-upload.jks \
     -alias murmur -keyalg RSA -keysize 2048 -validity 10000
   cp keystore.properties.example keystore.properties   # then fill in the path + passwords
   ```
   Play App Signing holds the app signing key; this is only the upload key. Back up the
   `.jks` and both passwords in the password manager.
3. **Users and permissions** → grant the service account (the JSON at
   `~/arkhe-android-signing/play-service-account.json`, or a new one saved to
   `~/murmur-android-signing/play-service-account.json`) **Release manager** on Murmur.
   Until this is done every upload stops at `403 The caller does not have permission`.
4. Store-listing minimums for internal testing: app name, short/full description
   placeholders, a privacy policy URL, and the Data Safety form — microphone audio is
   processed on device or sent to the user's chosen provider; Murmur collects nothing.

Then `scripts/android-play-upload.sh` builds and uploads (see `scripts/README.md`);
`node scripts/play-upload.mjs --aab <path> --dry-run` authenticates and reads the track
without uploading.

## Debug-only fake audio

An emulator has no microphone, so a debug build can be told to play a bundled 16 kHz mono
WAV (`app/src/debug/res/raw/sample_dictation.wav`) into the pipeline instead:

```bash
adb shell am start -n com.murmur.app/.MainActivity -e murmurFakeAudio 1
```

The flag is process-wide, so the keyboard picks it up too — the app and the IME share one
process. `-e murmurFakeAudio 0` clears it; so does killing the app.

**It only exercises the cloud path.** `FakeAudioSession` stands in for `AudioRecorder`,
which is the cloud engine's microphone; the on-device engine never uses an `AudioSession`
for audio at all, because Android's `SpeechRecognizer` opens the microphone itself and
cannot be handed a buffer. Real on-device dictation is the device gate below, not
something an emulator can show.

Everything is in `src/debug/java/com/murmur/app/debug/`; `src/release/java/` holds a
`DebugHooks` twin whose two methods do nothing, so neither the flag, nor the fake session,
nor the WAV exists in a release build.

## What the app does (MM3)

| Piece | Where | What |
|---|---|---|
| Input method | `app/src/main/java/com/murmur/app/ime/` | The Murmur voice keyboard. Opens listening (auto-listen), transcribes on-device (Android `SpeechRecognizer`) or through Groq/OpenAI via `murmur-core`, cleans, writes history, commits the text into the focused field, and returns to the previous keyboard. Globe / delete / space / return; no letter keys by design. |
| Pipeline | `engine/DictationPipeline.kt` | Same five rules as iOS. Android difference: the on-device recognizer records itself and cannot take a buffer, so a cloud failure offers **Try on device** instead of replaying silently. |
| Audio | `audio/` | `AudioRecorder` (16 kHz mono, cloud path only), `SilenceDetector`. |
| Data | `data/` | DataStore settings, `EncryptedSharedPreferences` secrets, Room history (same `transcripts` schema as the desktop). |
| Screens | `ui/` | Onboarding (mic → engine → keyboard → test), Home, Settings, History, and the in-app recorder that reuses `ImeController`. |

Everything the IME does is unit-tested with fakes (`ImeControllerTest`); the recorder and the real recognizer are exercised on the emulator/device.

### Debug-only screenshot mode

`adb shell am start -n com.murmur.app/.MainActivity -e murmurScreen home|history|settings|onboarding|recorder` opens a screen and seeds two history rows the first time. Compiled out of release.

### Device checklist (MM3)

1. Fresh install → onboarding: the mic prompt grants; Local shows ready (or Google's offline pack downloads); keyboard settings open and Murmur appears; enabling it flips the check.
2. In Messages: tap the field → keyboard switcher → Murmur → it starts listening immediately → speak → auto-stops → the text is committed with a trailing space → Gboard is back within half a second.
3. Settings → turn off auto-listen and return-to-keyboard → the keyboard waits for the mic tap and stays after committing; the globe returns to Gboard.
4. Settings → Groq key: "Get your API key ↗" opens the browser; paste → "✓ Connected"; Transcription = Groq → dictation works; airplane mode → **Try on device** appears and works.
5. Revoke the mic permission in system settings → the keyboard shows "Open Murmur to allow the microphone" → the button opens the app at the mic step.
6. Rotate the phone while listening — the keyboard survives and the dictation completes.
