# Murmur on a phone

The first release starts in a dedicated app: record, review, correct, then share.
The user requested iPhone first and Android too. A shared React interface keeps
interaction and learning rules consistent, while a small Swift/Java bridge uses
native on-device speech. The desktop Rust app remains independent.

The visual direction is quiet and editorial: warm paper, forest green, generous
spacing, a single dominant recording action, and a full editable draft. No fake
live waveform is used: the waveform is decorative and static; recording state
is expressed in visible text, color and screen-reader status. No information
requires motion or color alone. The primary screens are Dictate, Library,
Vocabulary and Settings. Large controls work without precise gestures.

The capture-to-correction loop is the product's center. Recognition hints learn
spelling, not a biometric voice model. A single manual "Remember" is explicit;
automatic learning is disabled until opted in and needs two independently
corrected saved drafts. A correction only proposes a short changed span, not a
whole rewritten paragraph. Terms never cause automatic global replacements.
Users can pause or forget words and inspect learned provenance counts. Each draft
contributes only its latest saved correction; reverting, re-editing or deleting
it retracts its former evidence. Disabling learning also pauses learned hints.

## Platform constraints

Apple's custom keyboard extension documentation excludes microphone access.
Therefore the app makes no claim that an iOS keyboard can directly dictate.
A future keyboard/share extension must be separately designed around legitimate
containing-app capture and platform review requirements. Android has a different
IME model, but an Android keyboard is also outside this release.

Apple Speech supports on-device requests only where the device and locale
support it. Murmur checks support and sets `requiresOnDeviceRecognition=true`.
Android uses `createOnDeviceSpeechRecognizer` on API 31+, checks availability,
and never swaps to the potentially network-backed default constructor.
Android API 33 adds biasing strings; older supported devices can save vocabulary
but may not apply those hints. Languages and service limits must be tested on
physical hardware; an engine's availability does not prove quality.

ChatGPT OAuth is not an audio transport. The parent desktop track investigates
eligible OAuth text cleanup. Mobile currently offers neither that login nor an
unsupported substitute. A later integration must preserve explicit data-flow
choices and evaluate whether mobile authorization fits the documented flow.

Primary sources consulted 2026-10-27:
- https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html
- https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition
- https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition
- https://developer.android.com/reference/android/speech/SpeechRecognizer
- https://developer.android.com/reference/android/speech/RecognizerIntent#EXTRA_BIASING_STRINGS
- https://capacitorjs.com/docs/ios/custom-code
- https://capacitorjs.com/docs/android/custom-code
- https://developer.android.com/reference/android/util/AtomicFile

## Before external distribution

The current state is an engineering preview. Build success is not device or
speech-quality validation. These gates remain:

1. Physical iPhone dictation: allow/deny/revoke permissions, supported/unsupported
   languages, no downloaded model, airplane mode, accents, names, long pauses,
   background/lock-screen/phone-call interruptions, finalization, repeated starts.
2. Physical Android checks across speech services: API 31 and 33+, service absent,
   model absent, permission denial, microphone in use, silence/end-of-speech,
   lifecycle cancellation and on-device-only behavior.
3. VoiceOver and TalkBack: all four screens, editable transcripts, error recovery,
   keyboard navigation and large text; verify actual Dynamic Type on iPhone.
4. Data recovery: force-close/relaunch, full storage, corrupt saved files, deletion,
   prior-version migration, and privacy expectations under OS backups.
5. Accuracy evaluation with consented held-out speech: names/terms before and
   after learning, false hints, accent/speech differences, stop-to-text latency.
6. Real application identity and release signing, TestFlight internal testing,
   App Store privacy answers/screenshots/support/privacy URLs, Google Play data
   safety and signing. No account credentials or release profiles are in git.
7. Human product review of visual design and key onboarding copy. Mobile should
   be explicitly labeled a preview until these checks pass.

A native SQLite migration, editable long-form notes, explicit import of desktop
vocabulary and optional text cleanup are logical next increments. Continuous
background dictation, sync and systemwide keyboard behavior need separate design
and testing rather than being implied by the first release.
