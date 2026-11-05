# Murmur mobile

An iPhone-first dictation companion, with Android support. Speak a short thought,
review the words, correct a name, and copy or share the result. This is a working
preview, not an App Store or Play Store release.

## What works

- Native on-device speech: Apple Speech on iOS 15+, Android's on-device
  `SpeechRecognizer` on Android 12+. There is no network-recognition fallback.
- Partial transcripts, stop/cancel, foreground-only recording, recovery of
  partial text after interruptions, and bounded recognition timeouts.
- An editable current draft and the most recent 100 saved drafts, with search,
  copy/share, and deletion. Edits persist in atomic files in the app’s private storage.
- A local vocabulary of up to 500 terms. Add names manually or opt into learning
  after the same correction appears in two different saved dictations. A saved
  draft cannot count twice. Re-editing, reverting, or deleting a draft retracts
  its previous correction evidence. Turning learning off pauses learned hints. Recognition receives at most 80 enabled hints;
  Android hint support requires Android 13+ and depends on its speech service.
- Review, pause, forget and export vocabulary. Export uses
  `{ "version": 1, "terms": [{ "term", "source", "observations", "enabled" }] }`.
- Screen-reader names/status, 48px primary touch targets, light/dark themes,
  system fonts, iOS Dynamic Type, safe-area layout, and reduced-motion support.

Availability depends on device, installed language models and speech service.
iOS recordings finish automatically after 55 seconds; Android's service may
finish on silence. This version is intended for short dictations. It does not
include a keyboard extension, cross-app insertion, cloud transcription, ChatGPT
cleanup, vocabulary sync/import, or background recording. Typed edits in other
apps cannot be learned by Murmur.

## Develop

Requirements: Node 22+, Xcode 26+ for iOS, Android SDK 36 and JDK 21 for Android.
The mobile project is isolated from the desktop project's dependencies.

```sh
cd mobile
npm ci
npm test
npm run build
npm run sync
npm run ios      # opens Xcode project
npm run android  # opens Android Studio project
```

Use `npm run dev -- --port 4178` to inspect the responsive UI in a browser.
The browser preview supports editing, saving and vocabulary; it deliberately
has no speech fallback and does not pretend to record. Browser state is isolated
from the native app. Only use synthetic text during preview/testing.

The native projects are checked in. Do not run `cap add` again. `npm run sync`
updates native web assets and plugin dependencies; retain our native bridge,
scene controller, manifest and icon changes.

### iPhone

Open `ios/App/App.xcodeproj` with `npm run ios`. Select your Apple development
team in Signing & Capabilities, choose an attached iPhone, and build/run. No
signing identity or provisioning profile is committed. The bundle identifier is
`com.murmur.mobile`; update it consistently if the team requires another ID.
The first recording asks for speech recognition and microphone permission.

Simulator compile check (does not validate microphone or speech accuracy):

```sh
xcodebuild -project ios/App/App.xcodeproj -scheme App -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ios/App/DerivedData CODE_SIGNING_ALLOWED=NO build
```

### Android

Select JDK 21 in Android Studio. With the standard macOS SDK/JDK locations:

```sh
JAVA_HOME='/Applications/Android Studio.app/Contents/jbr/Contents/Home' \
ANDROID_HOME="$HOME/Library/Android/sdk" \
./android/gradlew -p android assembleDebug
```

The debug APK is `android/app/build/outputs/apk/debug/app-debug.apk`. Android
versions below 12 can use text drafts but cannot record with this implementation.
For distribution, create a separate release signing configuration; never commit
keystores or passwords.

## Privacy and data

No account, analytics SDK, application backend, stored audio, or cloud fallback.
Apple recognition explicitly requires on-device processing; Android uses the
on-device constructor rather than merely requesting "prefer offline". The app
stores text and vocabulary in its sandbox. Device backups may include that data.
Copy and Share explicitly move the selected text outside Murmur. Vocabulary
export omits private correction-evidence identifiers. Delete-all resets current
draft, saved drafts, terms, and preferences after an in-app confirmation.

Native atomic snapshots are a bounded preview store, not an encrypted document vault.
Before scaling to large libraries, migrate to a transactional database and test
migration/recovery. Corrupt storage is surfaced without overwriting it. A write
failure leaves the draft visible and offers retry/copy recovery.

## Project map

- `src/App.tsx`: capture, library, vocabulary and settings UI.
- `src/domain.ts`: bounded learning, draft/history logic, export and validation.
- `src/storage.ts`: ordered writes to a versioned native file (atomic replacement).
- `src/speech.ts`: typed bridge contract.
- `ios/App/App/AppDelegate.swift`: native speech bridge and custom view controller.
- `ios/App/App/SceneDelegate.swift`: registers the custom bridge controller.
- `ios/App/App/AppDelegate.swift` also includes the atomic-file store bridge.
- `android/app/src/main/java/com/murmur/mobile/MurmurStorePlugin.java`: ordered
  atomic private-file storage on a background executor.
- `android/app/src/main/java/com/murmur/mobile/MurmurSpeechPlugin.java`: Android
  recognition service, permissions, events and lifecycle handling.
- `assets/icon.svg`, `scripts/icons.swift`: reproducible vector brand icon.

`package.json` overrides the Capacitor CLI's `xcode` package dependency on `uuid`
to the patched CommonJS-compatible 11.1.1 release. The xcode package uses only
`uuid.v4()`; Capacitor sync and native builds are verified with this override.

See [mobile design and release gates](../docs/mobile/DESIGN.md) for the platform
constraints and the remaining device-validation checklist.
