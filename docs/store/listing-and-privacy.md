# Murmur — store listing, privacy answers, and review notes (draft for MM4)

Everything below is copy Matt can paste. Placeholders are marked `[…]`. Keep the two stores' descriptions in sync.

## Name and one-liners

| Field | Value |
|---|---|
| App name | **Murmur** (fallback if taken on the App Store: **Murmur Dictation**) |
| Subtitle (App Store, 30 chars) | `Dictate into any app` |
| Short description (Play, 80 chars) | `Speak, and clean text lands in whatever you're typing. On-device or your own key.` |
| Category | Productivity (secondary: Utilities) |
| Age rating | 4+ / Everyone |
| Price | Free |
| Keywords (App Store, 100 chars) | `dictation,voice typing,speech to text,keyboard,transcribe,whisper,groq,voice keyboard,talk to type` |
| Support URL | `[https://murmur.app/support]` |
| Privacy policy URL | `[https://murmur.app/privacy]` (draft below) |
| Marketing URL | `[https://murmur.app]` |

## Description (both stores)

Murmur turns what you say into clean, punctuated text — inside any app.

**On iPhone:** add the Murmur keyboard and tap its mic, or press the Action Button, or tap the Murmur button in Control Center. Speak. Murmur transcribes, tidies up the filler words and punctuation, and types the result where your cursor was.

**On Android:** switch to the Murmur keyboard and it starts listening immediately. Speak, and the text is typed into the field and your usual keyboard comes straight back.

**Private by default.** Transcription runs on your device using the system's speech recognition. Nothing leaves your phone unless you choose to.

**Bring your own key.** Want the most accurate transcription and cleanup? Paste a Groq key (free tier, no card) or an OpenAI key. Audio goes only to the provider you pick, with your key, from your phone. Murmur has no servers, no account, and no subscription.

**Also on the Mac.** The same Murmur runs in the macOS menubar: hold a key, speak, and the text pastes at your cursor.

- Works in Messages, Mail, Notes, Safari, Slack — anywhere there's a text field
- Automatic stop when you pause; tap to stop sooner
- History with search, copy, and delete — every dictation is saved before it's typed, so nothing is ever lost
- Cleanup removes "um", "uh", and "like", fixes capitalization and punctuation, and never changes your meaning
- Cloud engines fall back to on-device if you're offline

Murmur is open source: `[https://github.com/mbartelt-bit/murmur]`

## What's new (first release)

First release: the Murmur keyboard, Action Button and Control Center dictation (iPhone), the Murmur voice keyboard (Android), on-device transcription, Groq and OpenAI bring-your-own-key engines, and history.

## App Store review notes (paste into "Notes" under App Review Information)

Murmur is a dictation keyboard. Please note:

1. The keyboard extension provides full typed-character input (letters, numbers, symbols) and a next-keyboard key, and works without Full Access. Full Access is only needed so the keyboard can read the finished dictation from the containing app via the App Group.
2. Keyboard extensions cannot use the microphone, so the keyboard's mic key opens the Murmur app to record (the same approach as other dictation keyboards). The app shows "Swipe back to your app" when done and the keyboard inserts the text on return. Dictation can also be started without the keyboard via the "Dictate with Murmur" shortcut (Action Button) or the Control Center control.
3. No account is needed. To test cloud transcription, Settings → Transcription → Groq and paste this demo key: `[demo Groq key — create a throwaway key for review and revoke it after approval]`. On-device transcription needs no key.
4. Microphone and Speech Recognition permissions are requested in onboarding. Transcripts are stored only on the device.

## App Privacy (App Store "nutrition label") answers

- **Data collected:** None. Murmur has no servers and no analytics.
- **Data linked to you:** None.
- **Tracking:** No.
- Audio and text are processed on device, or sent directly from the device to the third-party provider the user configured (Groq or OpenAI) using the user's own API key. That is a user-initiated transfer to a third party, not collection by the developer. Mention it in the privacy policy (below), and answer "No" to collection since the developer never receives it.
- Required-reason APIs declared in `PrivacyInfo.xcprivacy`: UserDefaults (`CA92.1`), file timestamps (`C617.1`).

## Play Data Safety answers

- **Does your app collect or share any of the required user data types?** Collected: No. Shared: **Yes — Audio (voice or sound recordings) and Messages/Other in-app text, shared with a third party only when the user has chosen a cloud engine and entered their own API key**, for the purpose of "App functionality", optional (the user can use on-device transcription instead), not for advertising, and the user can turn it off by choosing Local.
- **Is all user data encrypted in transit?** Yes (HTTPS to the provider).
- **Do you provide a way for users to request that their data is deleted?** Data lives on the device; the user deletes it in History or by uninstalling. Murmur holds nothing to delete.
- **Permissions:** `RECORD_AUDIO` (dictation), `INTERNET` (cloud engines only), `BIND_INPUT_METHOD` (the keyboard).
- The app is not designed for children.

## Screenshots to take (both stores)

1. The keyboard with the mic key in Messages (iOS) / the voice keyboard in Messages (Android) — the hero.
2. The recorder listening (iOS) / the keyboard listening (Android).
3. Settings with the three engines and the Groq "Free tier · no card" badge.
4. History.
5. iOS only: Control Center with the Murmur button.

Sizes: iPhone 6.9" (1320×2868) and 6.5" (1284×2778); Android phone 1080×2400 plus the 1024×500 feature graphic.

## Privacy policy (publish at the privacy URL)

**Murmur Privacy Policy** — last updated `[date]`

Murmur is a dictation app for iPhone, Android, and macOS made by `[ARKHE Software, LLC]`.

**What Murmur collects:** nothing. Murmur has no user accounts, no servers, and no analytics. We never receive your audio, your transcripts, or your API keys.

**What stays on your device:** your dictation history, your settings, and your API keys (stored in the iOS Keychain or Android's encrypted preferences). You can delete history in the app or by uninstalling.

**On-device transcription:** by default Murmur transcribes using your phone's built-in speech recognition (Apple Speech on iOS, Google's on-device recognizer on Android). Apple's and Google's own privacy policies govern those services.

**Cloud engines you choose:** if you enter a Groq or OpenAI API key, your audio (for transcription) and your transcript (for cleanup) are sent directly from your device to that provider, using your key, over an encrypted connection. Murmur is not in the middle. Those providers' terms and privacy policies apply; you can switch back to on-device at any time in Settings.

**Keyboard (iOS):** the Murmur keyboard requests Full Access only so it can read the finished dictation from the Murmur app through a shared container on your device. It does not send what you type anywhere.

**Children:** Murmur is not directed at children under 13.

**Contact:** `[support@murmur.app]`

Changes to this policy will be posted at this address.
