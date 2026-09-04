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
