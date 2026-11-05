# Murmur: personal dictation release plan

Owner-approved direction: MIT open source, accessible desktop experience,
automatic vocabulary learning, optional ChatGPT login, iPhone-first mobile with
Android support. Implementation began October 27, 2026.

## Product principles

- Get to the first successful dictation without an account or API key.
- Make recording state unmistakable and never silently discard a user's work.
- Preserve the speaker's meaning; learn only from user corrections.
- Explain where audio/text goes. Local vocabulary is not a promise that cloud
  requests stay on-device. No automatic change to a paid processing path.
- Support keyboard, screen readers, large text, reduced motion and motor-access
  alternatives as normal product requirements.

## This implementation

Desktop: coherent three-area interface, editable/searchable history with originals
and undo, explicit hold/toggle shortcuts, visible start/stop/cancel draft controls,
recovery text, local bounded vocabulary, opt-in repeated-correction learning,
export/reset, bounded cloud requests, cached local Whisper model, verified model
download, updated OpenAI STT model, experimental ChatGPT text cleanup, MIT license.

Mobile: native standalone iOS/Android recording, partial results, editable drafts,
copy/share, bounded local learning and vocabulary, explicit platform limitations.
iPhone first. See mobile/README.md and docs/mobile/DESIGN.md.

The desktop default local model remains English base Whisper. ChatGPT OAuth is
text-only. Desktop recording no longer depends on double-tap timing: select Hold
or Press once in Settings. A new shortcut pressed while processing is rejected
with an explanation; it does not queue a second dictation.

## Before public release

- Verify real microphone/recognition, shortcut release and cancel races, clipboard
  restoration/paste targeting, permissions and credential storage on clean OSes.
- Complete eligible-account OAuth, scope decline, expiry, refresh, revoke, model
  selection, rate limits and offline tests. See CHATGPT.md. Do not market it as
  subscription-funded speech recognition.
- Validate VoiceOver on macOS/iPhone, NVDA on Windows and TalkBack on Android;
  native focus transitions and announcements cannot be proven by DOM tests.
- Prepare Apple Developer ID signing/notarization and TestFlight provisioning;
  Windows signing/installer and Android release signing. Private credentials and
  distribution account access are not in the repository.
- Use a small opt-in pilot and record stop-to-text p50/p95, name accuracy, edits
  per 100 words, meaning changes, first-dictation completion and recovery rate.
  Compare identical held-out recordings across local/OpenAI/Groq; no superiority
  claim until measured. Do not upload personal recordings without consent.
- Publish signed installers, clear platform support and privacy notes, then
  configure authenticated signed updates with rollback testing. No updater is
  enabled until a release feed and signing ownership exist.

## Subsequent milestones (not implemented)

1. Multilingual desktop model selection, microphone picker, optional launch at
   login, downloadable quality tiers, and persistent retry of failed recordings
   with an explicit audio retention policy.
2. Streaming desktop transcripts and latency tuning using actual pilot evidence.
3. Per-app vocabulary/style, optional contact-name import, and explicit integration
   for corrections made in destination apps. No broad background text surveillance.
4. Portable vocabulary import/sync, mobile cloud cleanup and platform-specific
   cross-app input exploration. iOS keyboard extensions cannot record audio.
5. Durable mobile database migration and longer dictation sessions.

True speaker/acoustic adaptation is separate from vocabulary learning and needs a
supported recognition/training approach plus an evaluation showing improvement.

## Release communications

Call this a preview until the gates above pass. Distinguish automated checks,
simulator builds, actual device tests, signing, publishing and live availability.
Do not claim broad adoption or accessibility compliance from this implementation
alone. Keep progress and exact evidence in VALIDATION.md.
