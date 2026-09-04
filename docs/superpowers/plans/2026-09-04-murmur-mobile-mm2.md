# Murmur Mobile MM2 — iOS keyboard, Action Button, Control Center, TestFlight

**Goal:** Dictate into any app on iPhone. A voice-first but complete keyboard extension whose mic key opens Murmur to record and whose next appearance inserts the result; an App Intent so the Action Button, Back Tap, Siri, and an iOS 18 Control Center button start a dictation without the keyboard; the onboarding steps that get the keyboard enabled; and the first TestFlight build.

**Spec:** `docs/superpowers/specs/2026-09-03-murmur-mobile-design.md` §2 (constraints 1, 2, 5, 6 — read them again, they bound everything here), §5 onboarding steps 4–5, §6.1, §6.3, §6.4, §8, §9, §12. MM1 plan for the existing app API (`AppState`, `DictationRequest`, `RecorderViewModel`, `Handoff`, `Settings`, `Keychain`, `HistoryStore`).

**Branch / worktree:** `feat/mobile-core` in `~/murmur-wt/mobile-core` (or a fresh `feat/mobile-keyboard` worktree if MM0/MM1 have merged — same rules). Never touch `~/murmur`.

**Model split:** Opus implements one task per subagent; Fable reviews each diff.

## Global constraints (from the spec)

- **Guideline 4.4.1:** the keyboard must type characters, must work with Full Access off, must offer "next keyboard", and must not launch any app other than Settings — the mic key opening Murmur's own containing app is the one documented review risk; nothing else in the extension may open anything.
- **No microphone code in the extension.** Ever. No `AVAudioSession`, no `AVAudioEngine`, no Speech framework imports in `MurmurKeyboard`.
- **Memory:** the extension links `MurmurShared` only for `AppGroup`, `Settings`, `Handoff`, `HistoryStore` — never `MurmurCore` (the Rust core) and never the audio/speech files. Put the keyboard's logic in a new SwiftPM target `MurmurKeyboardCore` that depends on a slimmed `MurmurShared` product (see Task 1) so the link graph is explicit.
- Bundle ids: app `com.murmur.app`, keyboard `com.murmur.app.keyboard`, controls widget `com.murmur.app.controls`. App Group `group.com.murmur.app`, keychain access group as in MM1. Team `X9PU63GUAN`.
- URL contract: keyboard writes `Handoff.writePending(PendingDictation(session:requestedAt:))` then opens `murmur://dictate?session=<uuid>`. The intent path uses `Handoff.intentSession` (a fixed UUID) so the keyboard can pick up an Action Button dictation too.
- Copy: "Tap the mic to dictate", "Listening in Murmur…", "Turn on Full Access in Settings", "Insert", "Discard", "Swipe back to your app — the text will be inserted." (recorder, already in MM1).

## Verification gate

```bash
cd ~/murmur-wt/mobile-core && . "$HOME/.cargo/env"
scripts/build-core-mobile.sh ios && (cd apple && xcodegen generate)
xcodebuild -project apple/Murmur.xcodeproj -scheme Murmur -destination 'platform=iOS Simulator,name=iPhone 17' test
xcodebuild -project apple/Murmur.xcodeproj -scheme Murmur -destination 'generic/platform=iOS' -configuration Release build CODE_SIGNING_ALLOWED=NO   # all three targets compile for device
```
Plus the device gates in Task 6 (Matt).

---

## Task 1 ✅ `02c60bb` — Keyboard logic package: layout model + handoff controller (no UI)

**Files (create):** `apple/MurmurShared/Sources/MurmurKeyboardCore/KeyboardLayout.swift`, `.../KeyboardState.swift`, `.../KeyboardController.swift`, `apple/MurmurTests/KeyboardLayoutTests.swift`, `apple/MurmurTests/KeyboardControllerTests.swift`.
**Modify:** `apple/MurmurShared/Package.swift` — add product `MurmurKeyboardCore` (target depends on `MurmurShared`). Split nothing else yet; the extension target in Task 2 links `MurmurKeyboardCore` + `MurmurShared` and must not link `MurmurCore`; add a comment in `Package.swift` saying so.

**Produces:**
```swift
public enum KeyboardPage: Equatable { case letters, numbers, symbols }
public enum ShiftState: Equatable { case off, on, capsLock }
public enum Key: Equatable {
    case char(String)          // what the cap shows in lowercase letters page; `.char("a")`
    case shift, delete, numbers, symbols, letters, globe, mic, space, `return`
}
public struct KeyboardLayout {
    public static func rows(for page: KeyboardPage) -> [[Key]]   // letters: qwertyuiop / asdfghjkl / [shift] zxcvbnm [delete] / [numbers] [globe] [mic] [space] [return]; numbers: 1234567890 / -/:;()$&@" / [symbols] .,?!' [delete] / [letters] [globe] [mic] [space] [return]; symbols: []{}#%^*+= / _\|~<>€£¥• / [numbers] .,?!' [delete] / [letters] [globe] [mic] [space] [return]
    public static func text(for key: Key, shift: ShiftState) -> String?   // .char("a") + .on → "A"; space → " "; return → "\n"; non-text keys → nil
}
public struct KeyboardState: Equatable {
    public var page: KeyboardPage = .letters
    public var shift: ShiftState = .off
    public mutating func tapShift(now: TimeInterval)        // double-tap within 0.3 s → capsLock; single → toggle on/off
    public mutating func didInsert(_ text: String)          // .on → .off after one character (capsLock stays)
    public static func autoShift(contextBefore: String?) -> ShiftState   // .on at document start or after ". ", "! ", "? ", "\n"; else .off
}
public protocol TextProxy { func insertText(_ s: String); func deleteBackward(); var contextBefore: String? { get } }
public protocol URLOpening { func open(_ url: URL) -> Bool }
public enum KeyboardPhase: Equatable { case idle, needsFullAccess, waiting(session: UUID, since: Date), preview(DictationResult), inserted }
public final class KeyboardController: ObservableObject {
    @Published public private(set) var phase: KeyboardPhase
    @Published public var state: KeyboardState
    public init(defaults: UserDefaults = AppGroup.defaults, urlOpener: URLOpening, hasFullAccess: @escaping () -> Bool, clock: @escaping () -> Date = Date.init, pollInterval: TimeInterval = 0.5, waitTimeout: TimeInterval = 60)
    public func viewWillAppear()          // writes the fullAccess heartbeat (key "keyboard.fullAccess", Bool + "keyboard.lastSeen", Date); then checkForResult()
    public func checkForResult()         // pending session → Handoff.takeResult(for:) ; else Handoff.takeResult(for: Handoff.intentSession) ; on hit → phase = .preview(result) if settings say confirm, else insert immediately (default: insert immediately, phase .inserted → .idle after 2 s)
    public func tapMic()                 // !hasFullAccess() → .needsFullAccess ; else session = UUID(); Handoff.writePending; open murmur://dictate?session=; phase = .waiting; start polling every pollInterval until result or waitTimeout
    public func tap(_ key: Key, proxy: TextProxy)   // applies KeyboardLayout.text + KeyboardState; delete → proxy.deleteBackward(); page keys switch page; globe/mic handled by the view controller/tapMic
    public func insertPreview(proxy: TextProxy); public func discardPreview()
    public func openSettings()           // urlOpener.open(URL(string: "app-settings:")!) — the only app the keyboard may open besides Murmur
}
extension Handoff { public static let intentSession = UUID(uuidString: "00000000-0000-4000-8000-000000000001")! }
```
**Tests:** `KeyboardLayoutTests` — every key on every page produces exactly its cap text (`text(for:shift:)`), shift uppercases letters only, `autoShift` cases, caps-lock via double tap, `.on` resets after one insert. `KeyboardControllerTests` — with a fake `URLOpening`, scripted `hasFullAccess`, throwaway `UserDefaults`, and an injected clock: mic without Full Access → `.needsFullAccess` and no URL opened; mic with Full Access → pending written, correct URL opened, `.waiting`; a result written for that session → picked up on `checkForResult` and inserted once through a fake `TextProxy`; wrong session ignored; intent-session result inserted; timeout returns to `.idle`; heartbeat written on `viewWillAppear`.

**Commit:** `feat(ios): keyboard layout model and handoff controller`.

---

## Task 2 ✅ `5ced018` — The keyboard extension target and UI

**Files (create):** `apple/MurmurKeyboard/KeyboardViewController.swift` (UIInputViewController), `apple/MurmurKeyboard/KeyboardView.swift` (SwiftUI, hosted by `UIHostingController` inside `inputView`), `apple/MurmurKeyboard/KeyCap.swift`, `apple/MurmurKeyboard/StatusStrip.swift`, `apple/MurmurKeyboard/Info.plist` (generated by xcodegen from `project.yml` `info:` block), `apple/MurmurKeyboard/MurmurKeyboard.entitlements`.
**Modify:** `apple/project.yml` — new target `MurmurKeyboard` (`type: app-extension`, `platform: iOS`, sources `MurmurKeyboard`, dependencies `[{ package: MurmurShared, product: MurmurKeyboardCore }, { package: MurmurShared, product: MurmurShared }]`, settings `PRODUCT_BUNDLE_IDENTIFIER: com.murmur.app.keyboard`, `GENERATE_INFOPLIST_FILE: NO`, `SKIP_INSTALL: YES`; `info.properties`: `NSExtension: { NSExtensionPointIdentifier: com.apple.keyboard-service, NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).KeyboardViewController, NSExtensionAttributes: { IsASCIICapable: false, PrefersRightToLeft: false, PrimaryLanguage: en-US, RequestsOpenAccess: true } }`; entitlements = App Group + keychain group like the app); the `Murmur` app target gets `dependencies: [{ target: MurmurKeyboard, embed: true }]`. Regenerate.

**Behaviour (per spec §6.1):**
- `KeyboardViewController`: builds `KeyboardController(urlOpener: ResponderChainOpener(self), hasFullAccess: { self.hasFullAccess })`; `viewWillAppear` → `controller.viewWillAppear()`; `textDidChange` → `controller.checkForResult()`; sets `inputView` height to 216 pt (portrait) / 162 pt (landscape) via a height constraint; `needsInputModeSwitchKey` drives whether the globe key is shown; globe → `advanceToNextInputMode()`; `hasFullAccess` from `UIInputViewController.hasFullAccess`.
- `ResponderChainOpener`: walks `next` responders to find an object responding to `open(_:options:completionHandler:)` (that is `UIApplication`) and performs it — the pattern shipping dictation keyboards use; it is the *only* `open` call in the extension besides `app-settings:`.
- `KeyboardView`: the layout from `KeyboardLayout.rows(for:)`; key caps sized to the screen width with system-keyboard proportions, `UIColor.systemBackground`/secondary key colours per light/dark, indigo mic key; delete auto-repeats on long press (0.4 s delay, 0.1 s interval); `StatusStrip` above the rows shows `phase`: idle text, "Listening in Murmur…" with a spinner while waiting, the preview with **Insert** / **Discard**, and for `.needsFullAccess` a one-line explainer + **Settings** button.
- Full Access off: everything types; mic shows the explainer; nothing else changes.
- Haptics: `UIImpactFeedbackGenerator(style: .light)` on key down when Full Access is on (haptics need it); silently skipped otherwise.

**Tests:** `apple/MurmurTests/KeyboardViewSnapshotSmokeTests.swift` is NOT a snapshot test — it just instantiates `KeyboardView` for each page/phase inside a `UIHostingController` and asserts it lays out with a positive height (catches crashes). All logic remains covered by Task 1's tests. Also the device-build compile check from the verification gate.

**Commit:** `feat(ios): Murmur keyboard extension (QWERTY + mic hand-off)`.

---

## Task 3 ✅ `1f71cd1` — App Intent, App Shortcuts, Control Center control

**Files (create):** `apple/MurmurShared/Sources/MurmurIntents/DictateIntent.swift`, `.../MurmurShortcuts.swift`, `apple/MurmurControls/MurmurControls.swift` (ControlWidget bundle), `apple/MurmurControls/Info.plist`, `apple/MurmurControls/MurmurControls.entitlements`.
**Modify:** `Package.swift` (new product/target `MurmurIntents`, depends on `MurmurShared`), `project.yml` (target `MurmurControls`: `type: app-extension`, `NSExtensionPointIdentifier: com.apple.widgetkit-extension`, bundle `com.murmur.app.controls`, App Group entitlement, embedded by the app; both `Murmur` and `MurmurControls` link `MurmurIntents`), `apple/Murmur/AppState.swift` (react to the launch flag), `apple/Murmur/MurmurApp.swift` (`.onChange(of: scenePhase)`).

**Produces:**
```swift
public struct DictateIntent: AppIntent {
    public static let title: LocalizedStringResource = "Dictate with Murmur"
    public static let description = IntentDescription("Start a Murmur dictation. The text is copied to the clipboard and inserted if the Murmur keyboard is active.")
    public static let openAppWhenRun = true
    public init()
    public func perform() async throws -> some IntentResult   // AppGroup.defaults.set("action-button", forKey: "launch.dictate"); return .result()
}
public struct MurmurShortcuts: AppShortcutsProvider { public static var appShortcuts: [AppShortcut] }   // phrases: "Dictate with \(.applicationName)", "Start \(.applicationName)"; systemImageName "mic.fill"
```
`AppState.consumeLaunchFlag()` — on `scenePhase == .active` (and on `onOpenURL`), if `launch.dictate` is set, remove it and set `activeDictation = DictationRequest(session: Handoff.intentSession, source: .actionButton)`. The recorder already writes a `Handoff` result for any non-nil session, so the keyboard's intent-session pickup (MM2 Task 1) works with no recorder change; `RecorderViewModel.showsSwipeBackHint` stays true only for keyboard sessions — add `request.source == .keyboard` to that condition.
`MurmurControls`: `@available(iOS 18, *) struct DictateControl: ControlWidget` → `ControlWidgetButton(action: DictateIntent()) { Label("Dictate", systemImage: "mic.fill") }`, kind `com.murmur.app.controls.dictate`, `displayName "Murmur Dictate"`, `description "Start a dictation"`.

**Tests:** `apple/MurmurTests/DictateLaunchTests.swift` — `AppState.consumeLaunchFlag()` with a throwaway `UserDefaults`: flag set → `activeDictation` has `intentSession` + `.actionButton` and the flag is cleared; no flag → nothing. Intent `perform()` writes the flag (call it directly).

**Commit:** `feat(ios): Dictate app intent, App Shortcuts, and Control Center button`.

---

## Task 4 ✅ `97d6ed9` — Onboarding steps for the keyboard and triggers; Home status

**Files (modify):** `apple/Murmur/Onboarding/OnboardingViewModel.swift` + `OnboardingView.swift` (append `Step.keyboard` after `.engine` and `Step.triggers` before `.test`), `apple/Murmur/Home/HomeViewModel.swift` + `HomeView.swift` (chips: Keyboard enabled / Full Access / Action Button hint), `apple/MurmurShared/Sources/MurmurShared/KeyboardStatus.swift` (create), `apple/MurmurTests/OnboardingViewModelTests.swift` (extend), `apple/MurmurTests/KeyboardStatusTests.swift` (create).

**Produces:**
```swift
public enum KeyboardStatus {
    public static let extensionBundleId = "com.murmur.app.keyboard"
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool   // (defaults.object(forKey: "AppleKeyboards") as? [String])?.contains(extensionBundleId) == true
    public static func hasFullAccess(appGroup: UserDefaults = AppGroup.defaults, now: Date = .init()) -> Bool?   // heartbeat "keyboard.fullAccess" if "keyboard.lastSeen" within 7 days, else nil (unknown)
    public static func openKeyboardSettings()   // UIApplication.open(URL(string: UIApplication.openSettingsURLString)!) — iOS has no deeper public link; the step's copy explains the path Settings → General → Keyboard → Keyboards → Add New Keyboard → Murmur, then tap Murmur → Allow Full Access
    public static var hasActionButton: Bool     // model identifier iPhone16,1 / 16,2 / 17,x and later (a small allow-list + "newer than" rule)
}
```
Onboarding `Step.keyboard`: illustrated three-line instruction, **Open Settings** button, polls `KeyboardStatus.isEnabled` every 1 s while the app is active; shows a green check when enabled; a second row for Full Access shows "Check" (unknown until the keyboard has appeared once) → the copy says "Open any app, switch to Murmur once, then come back"; `canAdvance` requires enabled; Full Access can be skipped with "Later" (the keyboard explains it again). `Step.triggers` (iOS only): shows the Control Center instructions on every iPhone (iOS 18+) and the Action Button instructions when `hasActionButton`; "Test it" launches the in-app recorder with `source: .actionButton`; skippable.
Home chips: "Keyboard · On/Off" (tap → settings), "Full Access · On/Off/Unknown", "Action Button · Set up" (only when `hasActionButton`).

**Tests:** step ordering and gating (keyboard step blocks until enabled; triggers step always skippable); `KeyboardStatus.isEnabled` against a fake `AppleKeyboards` array; `hasFullAccess` nil when stale.

**Commit:** `feat(ios): keyboard + trigger onboarding steps and home status chips`.

---

## Task 5 ✅ `fc10829` — Crash safety: finish the last dictation

**Files:** `apple/MurmurShared/Sources/MurmurShared/Audio/RecordingJournal.swift` (create), `apple/Murmur/Recorder/RecorderViewModel.swift` + `apple/Murmur/Home/HomeViewModel.swift` (modify), `apple/MurmurTests/RecordingJournalTests.swift` (create).

Spec §9: "App killed mid-recording → recorder writes samples to a temp file every 2 s; on next launch offers 'Finish last dictation'." `RecordingJournal(url:)` appends `samples16kMono` as raw Float32 every 2 s of audio (`append(_:)`, `flush()`), `discard()` deletes; `RecordingJournal.pending(in:)` finds a leftover file older than 5 s; Home shows a banner "Finish last dictation?" with **Finish** (runs `DictationPipeline.run` over the journaled samples through the cloud/local engine that accepts a buffer — for the local engine on iOS 26 feed the analyzer from the file; for legacy feed `SFSpeechAudioBufferRecognitionRequest`) and **Discard**. Tests: append/flush/pending/discard round trip with a temp dir.

**Commit:** `feat(ios): journal in-flight recordings and offer to finish them after a crash`.

---

## Task 6 ✅ (script + docs landed; device gates + ASC app record pending Matt) — Device gates, signing, TestFlight

**Files:** `scripts/ios-testflight.sh` (create), `apple/README.md` + `docs/HANDOFF.md` (modify).

`scripts/ios-testflight.sh`: `xcodebuild -project apple/Murmur.xcodeproj -scheme Murmur -configuration Release -destination 'generic/platform=iOS' -archivePath target/ios/Murmur.xcarchive archive` (automatic signing, `DEVELOPMENT_TEAM=X9PU63GUAN`, `-allowProvisioningUpdates`), then `xcodebuild -exportArchive -archivePath … -exportOptionsPlist apple/ExportOptions.plist -exportPath target/ios/export` (method `app-store-connect`, `uploadSymbols true`), then `xcrun altool --upload-app -f target/ios/export/Murmur.ipa -t ios --apiKey 383GDWSM4D --apiIssuer "$ASC_ISSUER_ID"` (the key file is already at `~/.appstoreconnect/private_keys/AuthKey_383GDWSM4D.p8`; the issuer id lives in `~/arkhe-native-release-tools/asc.mjs` — read it from there, never commit it). Bump `CFBundleVersion` automatically to the current UTC `yyyyMMddHHmm`.

**[MATT] steps, in order, before the script can succeed:**
1. App Store Connect → My Apps → **+ New App**: platform iOS, name **Murmur** (if taken, **Murmur Dictation**), bundle id `com.murmur.app` (Xcode's automatic signing registers the identifier, the App Group, and the keyboard/controls identifiers on the first device build — do a device build from Xcode once with the iPhone plugged in), SKU `murmur-ios`, primary language English (US).
2. iPhone plugged in and unlocked: run the app from Xcode once so the App Group and identifiers get registered; accept the "register device" prompt.
3. Run through the device gates below; then `scripts/ios-testflight.sh`; then add yourself as an internal tester in TestFlight.

**Device gates (Matt):**
1. Settings → General → Keyboard → Keyboards → Add New Keyboard → Murmur appears; enable; Allow Full Access.
2. In Messages: switch to Murmur (globe), type a word with the letters, numbers and symbols pages, shift and caps lock behave like the system keyboard, delete repeats on hold.
3. Tap the mic → Murmur opens and starts listening within a second → speak → auto-stops → shows "Swipe back to your app" → swipe back → the text appears in the Messages field once. Repeat in Safari's address bar (should auto-switch to the system keyboard for URL fields as iOS decides) and in Notes.
4. Full Access off: typing works; mic shows the explainer; Settings button opens Settings.
5. Control Center: add the Murmur control; tap it from the Lock Screen → recorder → text on the clipboard; with the Murmur keyboard active in Notes, the text also inserts on return.
6. iPhone 15 Pro+ only: Settings → Action Button → Shortcut → "Dictate with Murmur"; hold → same as 5.
7. Force-quit Murmur mid-recording → relaunch → "Finish last dictation?" banner → Finish → text appears in History.

**Commit:** `build(ios): TestFlight archive/upload script; MM2 device checklist`.

---

## Review checklist (Fable, after each task)
1. `grep -rn "AVAudio\|import Speech\|MurmurCore" apple/MurmurKeyboard apple/MurmurShared/Sources/MurmurKeyboardCore` is empty.
2. The extension opens only `murmur://` (via the responder chain) and `app-settings:`; grep for `open(` in `apple/MurmurKeyboard` confirms.
3. Every key on every page has a test asserting its inserted text.
4. Handoff pickup is session-matched and insert-once (tests from MM1 T1 + MM2 T1 both still pass).
5. `project.yml` regenerates cleanly; the app embeds both extensions; `SKIP_INSTALL: YES` on both.
6. No transcript text or key value is logged anywhere.
