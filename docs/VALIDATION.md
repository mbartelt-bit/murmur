# Preview validation — October 27, 2026

This is a development preview, not a signed public release. No live credentials,
real microphone sessions or production deployment were used for these checks.

## Desktop

- Frontend: 31 tests across 10 files passed; production build passed.
- Rust: 52 tests passed, 1 ignored audio fixture test, 1 real Keychain test
  deliberately filtered out. OAuth tests use fixtures, not a live account.
- The ignored local-audio test was then run separately against the verified
  Whisper base.en model and public whisper.cpp JFK sample. Two consecutive
  recognitions and explicit cache teardown passed with process exit 0.
- SQLite migration preserved original/raw text and added nullable corrections.
- macOS debug application bundle built successfully. It is not a signed,
  notarized installer. Windows/Linux native builds remain CI/device checks.
- Browser preview: Dictation, Your Words and Settings had no axe violations
  under WCAG 2 A/AA and 2.1 AA tags. A 520px viewport had no horizontal overflow.
  This does not establish screen-reader or native accessibility compliance.
- npm audit reported zero advisories.

## Mobile

- 12 tests across 3 files passed; frontend build and Capacitor sync passed.
- iOS simulator and generic device SDK debug builds passed with signing disabled.
- Android debug APK built successfully.
- iPhone simulator launched the native app and restored a synthetic saved draft.
- Browser checks at 390px and 320px, including 200% type in Vocabulary/Settings,
  found no horizontal overflow. Editing, saving, copying UI state, manual terms
  and reload persistence were exercised. Native share/speech need device checks.
- npm audit reported zero advisories.

The repository workflows now cover desktop checks and mobile web/native builds.
Remote CI results are separate from the local evidence above.

## Release gates

Physical iPhone first: real speech, permissions, interruptions, long sessions,
VoiceOver, storage recovery and share sheet. Repeat on Android with TalkBack.
Desktop needs clean-OS microphone, shortcut, paste, clipboard and credential
checks. Live ChatGPT eligibility, login, refresh and revoke remain unverified.
Signing, TestFlight, store submission and public release have not been performed.
See [the release plan](PRODUCT-PLAN.md) for pilot metrics and subsequent work.
