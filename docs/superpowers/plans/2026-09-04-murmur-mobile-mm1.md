# Murmur Mobile MM1 — iOS containing app

**Goal:** Turn the MM0 iOS shell into the real Murmur app: onboarding, home, settings, history, and the native recorder that runs a full dictation (mic → on-device Apple speech or cloud STT → cleanup → history → App Group handoff + clipboard). After MM1 a user can dictate inside Murmur end to end on an iPhone. The keyboard extension and Action Button arrive in MM2 and consume what MM1 writes.

**Spec:** `docs/superpowers/specs/2026-09-03-murmur-mobile-design.md` §5 (containing apps), §6.2 (recording screen), §8 (data flow), §9 (errors), §10 (security), §11 (tests). Read those first. MM0 plan (`2026-09-03-murmur-mobile-mm0.md`) describes what already exists.

**Branch / worktree:** continue on `feat/mobile-core` in `~/murmur-wt/mobile-core` (MM0 merged or not, this branch builds on it). Never touch `~/murmur`.

**Model split:** Opus implements one task per subagent; Fable reviews each diff before the next task.

## Global constraints (from the spec)

- Bundle id `com.murmur.app`, team `X9PU63GUAN`, min iOS 17, Swift 5.10, SwiftUI. App Group `group.com.murmur.app`. Keychain access group `$(AppIdentifierPrefix)com.murmur.app`. Keychain account names are the desktop's: `openai_api_key`, `groq_api_key`.
- Keys never leave the Keychain except to be passed into a `murmur-core` call. Never in UserDefaults, the App Group, logs, or history.
- Local engine = Apple on-device speech: `SpeechAnalyzer`/`SpeechTranscriber` on iOS 26+, `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true` on iOS 17–25. Cloud = `murmur-core` (`transcribeCloud`, `cleanText`, `verifyProvider`). Cleanup rules fallback is inside the core; the app never loses words.
- Every transcript is written to history **before** insertion/handoff. Empty transcripts insert nothing and show "Didn't catch that."
- Visual language: system fonts, indigo accent `#6366f1` (`Color(red: 0.388, green: 0.4, blue: 0.945)`), system light/dark, the recording dot + squiggle from the Mac HUD.
- Logic lives in `ObservableObject` view models or plain types so it is testable with XCTest on the simulator; views stay thin.
- All new files under `apple/`; `project.yml` is the source of truth (run `xcodegen generate` after editing it and commit the regenerated pbxproj). Build outputs stay gitignored.

## Verification gate for the milestone

```bash
cd ~/murmur-wt/mobile-core && . "$HOME/.cargo/env"
scripts/build-core-mobile.sh ios
(cd apple && xcodegen generate)
xcodebuild -project apple/Murmur.xcodeproj -scheme Murmur -destination 'platform=iOS Simulator,name=iPhone 17' test
```
Plus the device gates (only Matt can run these, listed in Task 6).

---

## Task 1 — Shared foundations: App Group, settings, keychain, handoff

**Files (create):**
- `apple/MurmurShared/Sources/MurmurShared/AppGroup.swift`
- `apple/MurmurShared/Sources/MurmurShared/Settings.swift`
- `apple/MurmurShared/Sources/MurmurShared/Keychain.swift`
- `apple/MurmurShared/Sources/MurmurShared/Handoff.swift`
- `apple/Murmur/Murmur.entitlements`
- `apple/MurmurTests/SettingsTests.swift`, `apple/MurmurTests/HandoffTests.swift`, `apple/MurmurTests/KeychainTests.swift`

**Modify:** `apple/project.yml` — app target gets `entitlements: { path: Murmur/Murmur.entitlements, properties: { com.apple.security.application-groups: [group.com.murmur.app], keychain-access-groups: ["$(AppIdentifierPrefix)com.murmur.app"] } }`; the test target inherits the app's entitlements automatically as a hosted test. Add `MurmurShared`'s `Package.swift` a dependency on GRDB (`https://github.com/groue/GRDB.swift`, `from: "7.11.1"`; GRDB 7.9+ needs the Swift 6.1 compiler, which Xcode 26.6 has — our targets stay in Swift 5 language mode) for Task 2 (declare now so the project regenerates once).

**Produces (exact API, used by every later task):**
```swift
public enum AppGroup {
    public static let id = "group.com.murmur.app"
    public static var defaults: UserDefaults          // UserDefaults(suiteName: id)!, falls back to .standard in a DEBUG-only unit-test environment where the suite is unavailable
    public static var containerURL: URL               // FileManager.containerURL(forSecurityApplicationGroupIdentifier:) ?? temporaryDirectory
}

public enum SttEngine: String, Codable, CaseIterable { case local, groq, openai }
public enum CleanupEngine: String, Codable, CaseIterable { case rule, groq, openai }
public enum ProviderId: String, Codable, CaseIterable { case groq, openai
    public var keychainAccount: String   // "groq_api_key" / "openai_api_key"
    public var core: MurmurCore.Provider // .groq / .openAi
    public var displayName: String       // "Groq" / "OpenAI"
    public var costLabel: String         // "Free tier · no card" / "Pay as you go · ~$0.006/min"
    public var signupSteps: [String]     // copied from src/components/EngineSettings.tsx PROVIDER_INFO
}
public struct Settings: Codable, Equatable {
    public var stt: SttEngine = .local
    public var cleanup: CleanupEngine = .rule
    public var autoStopOnSilence = true
    public var copyToClipboard = true
    public var onboardingComplete = false
}
public final class SettingsStore: ObservableObject {
    @Published public private(set) var settings: Settings
    public init(defaults: UserDefaults = AppGroup.defaults)   // key "settings.v1", JSON
    public func update(_ change: (inout Settings) -> Void)      // mutates, persists, publishes
}

public protocol SecretStore { func get(_ account: String) throws -> String?; func set(_ account: String, _ value: String) throws; func delete(_ account: String) throws }
public struct Keychain: SecretStore { public init(service: String = "com.murmur.app", accessGroup: String? = Keychain.defaultAccessGroup) }
// Keychain.defaultAccessGroup reads the app's team prefix at runtime; on the simulator without a provisioning profile, access groups are ignored, so the tests pass either way.
public final class InMemorySecretStore: SecretStore { public init() }   // for tests and previews

public struct PendingDictation: Codable, Equatable { public var session: UUID; public var requestedAt: Date }
public struct DictationResult: Codable, Equatable { public var session: UUID; public var raw: String; public var clean: String; public var createdAt: Date; public var inserted: Bool }
public enum Handoff {   // App Group UserDefaults keys "handoff.pending" / "handoff.result", JSON
    public static let expiry: TimeInterval = 600
    public static func writePending(_ p: PendingDictation, defaults: UserDefaults = AppGroup.defaults)
    public static func readPending(now: Date = .init(), defaults: UserDefaults = AppGroup.defaults) -> PendingDictation?   // nil if expired (now - requestedAt > expiry)
    public static func clearPending(defaults:)
    public static func writeResult(_ r: DictationResult, defaults:)
    public static func takeResult(for session: UUID, now: Date = .init(), defaults:) -> DictationResult?  // returns the result only if session matches, not inserted, not expired; marks inserted + clears pending
    public static func clearResult(defaults:)
}
```

**Tests:** `SettingsTests` (default values; update persists and re-reads through a fresh `SettingsStore` on the same `UserDefaults(suiteName: "test.\(UUID())")`); `HandoffTests` (write/take round trip; wrong session → nil and result untouched; expired pending → nil; `takeResult` twice → second is nil); `KeychainTests` (round trip + delete on the real Keychain in the simulator, using a `test-` account, cleaned up in `tearDown`; plus the same suite run against `InMemorySecretStore` via a shared helper).

**Commit:** `feat(ios): App Group settings store, keychain, and dictation handoff codec`.

---

## Task 2 — History store (GRDB)

**Files (create):** `apple/MurmurShared/Sources/MurmurShared/HistoryStore.swift`, `apple/MurmurTests/HistoryStoreTests.swift`.

**Produces:**
```swift
public struct Transcript: Codable, Equatable, Identifiable { public var id: Int64?; public var rawText: String; public var cleanText: String; public var source: TranscriptSource; public var createdAt: Date }
public enum TranscriptSource: String, Codable { case inApp = "in-app", keyboard, actionButton = "action-button" }
public final class HistoryStore {
    public init(url: URL) throws            // AppGroup.containerURL.appendingPathComponent("murmur.sqlite") in the app
    public static func inMemory() throws -> HistoryStore
    @discardableResult public func insert(_ t: Transcript) throws -> Transcript   // returns with id
    public func list(limit: Int = 50, matching query: String? = nil) throws -> [Transcript]  // newest first; query = case-insensitive LIKE on clean_text OR raw_text
    public func delete(id: Int64) throws
    public func recent(_ n: Int) throws -> [Transcript]
}
```
Migration `v1`: table `transcripts(id INTEGER PRIMARY KEY AUTOINCREMENT, raw_text TEXT NOT NULL, clean_text TEXT NOT NULL, source TEXT NOT NULL, created_at DATETIME NOT NULL)` — same column names as the desktop's SQLite so a future sync is trivial.

**Tests:** insert → list order; search matches raw or clean; delete removes; `recent(3)` returns three newest.

**Commit:** `feat(ios): GRDB history store mirroring the desktop transcripts table`.

---

## Task 3 — Audio capture, local speech engines, and the dictation pipeline

**Files (create):**
- `apple/MurmurShared/Sources/MurmurShared/Audio/AudioCapture.swift`
- `apple/MurmurShared/Sources/MurmurShared/Audio/SilenceDetector.swift`
- `apple/MurmurShared/Sources/MurmurShared/Speech/SpeechEngine.swift`
- `apple/MurmurShared/Sources/MurmurShared/Speech/AnalyzerSpeechEngine.swift` (iOS 26+, `@available(iOS 26, *)`)
- `apple/MurmurShared/Sources/MurmurShared/Speech/LegacySpeechEngine.swift` (`SFSpeechRecognizer`)
- `apple/MurmurShared/Sources/MurmurShared/Speech/CloudSpeechEngine.swift`
- `apple/MurmurShared/Sources/MurmurShared/Pipeline/DictationPipeline.swift`
- `apple/MurmurShared/Sources/MurmurShared/Pipeline/Permissions.swift`
- `apple/MurmurTests/SilenceDetectorTests.swift`, `apple/MurmurTests/DictationPipelineTests.swift`

**Produces:**
```swift
public struct AudioChunk { public var samples16kMono: [Float]; public var level: Float /* rms 0..1 */; public var buffer: AVAudioPCMBuffer /* native format, for the analyzer */ }
public protocol AudioSource { func start() throws -> AsyncStream<AudioChunk>; func stop() }
public final class AudioCapture: AudioSource { public init() }   // AVAudioEngine input tap, bufferSize 4096; converts to 16 kHz mono Float32 with AVAudioConverter for `samples16kMono`; AVAudioSession category .record, mode .measurement
public struct SilenceDetector {   // pure, testable
    public init(threshold: Float = 0.015, hangover: TimeInterval = 1.5, minSpeech: TimeInterval = 0.4)
    public mutating func feed(level: Float, at t: TimeInterval) -> Bool   // true when speech has been heard for >= minSpeech and then silence for >= hangover
}
public protocol SpeechEngine { func transcribe(_ audio: AsyncStream<AudioChunk>, partial: @escaping (String) -> Void) async throws -> String }
public enum SpeechEngines {
    public static func local() -> SpeechEngine          // AnalyzerSpeechEngine if #available(iOS 26), else LegacySpeechEngine
    public static func cloud(_ cfg: MurmurCore.CloudConfig) -> SpeechEngine   // buffers samples16kMono, then MurmurCore.transcribeCloud
    public static func isLocalAvailable() async -> Bool  // installed locale (analyzer) or supportsOnDeviceRecognition (legacy)
    public static func prepareLocalAssets() async throws // iOS 26: AssetInventory.assetInstallationRequest(supporting:) → downloadAndInstall(); AssetInventory.reserve(locale:) (respect AssetInventory.maximumReservedLocales); no-op pre-26
}
public enum PipelineError: Error, Equatable { case micDenied, speechDenied, noSpeechEngine, cloud(String), empty }
public struct PipelineOutcome: Equatable { public var transcript: Transcript; public var usedCloudStt: Bool; public var usedCloudCleanup: Bool }
public final class DictationPipeline {
    public init(settings: SettingsStore, secrets: SecretStore, history: HistoryStore, localEngine: @escaping () -> SpeechEngine = SpeechEngines.local, cloudEngine: @escaping (CloudConfig) -> SpeechEngine = SpeechEngines.cloud, clean: @escaping (String, CloudConfig?) async -> CleanResult = MurmurCore.cleanText)
    public func run(audio: AsyncStream<AudioChunk>, source: TranscriptSource, partial: @escaping (String) -> Void) async throws -> PipelineOutcome
    // 1. choose STT: settings.stt == .local → localEngine(); else cloud with key from secrets (missing key → fall back to local, record usedCloudStt=false)
    // 2. cloud STT failure → retry with local once; local failure → throw
    // 3. raw.trim.isEmpty → throw .empty (nothing written)
    // 4. cleanup: settings.cleanup == .rule → clean(raw, nil) else clean(raw, cfg) (the core falls back to rules itself)
    // 5. history.insert BEFORE returning
}
public enum Permissions {
    public static func micStatus() -> PermissionStatus; public static func requestMic() async -> Bool   // AVAudioApplication
    public static func speechStatus() -> PermissionStatus; public static func requestSpeech() async -> Bool   // SFSpeechRecognizer.requestAuthorization
    public static func openSettings()   // UIApplication.openSettingsURLString
}
public enum PermissionStatus { case notDetermined, granted, denied }
```
Implementation notes for the implementer: `AnalyzerSpeechEngine` follows the iOS 26 pattern — `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:[.volatileResults]:attributeOptions:)`, `SpeechAnalyzer(modules:)`, `bestAvailableAudioFormat(compatibleWith:)`, convert each `AudioChunk.buffer` with `AVAudioConverter` to that format and `yield(AnalyzerInput(buffer:))` into an `AsyncStream<AnalyzerInput>` fed to `analyzer.start(inputSequence:)`; read `transcriber.results`, call `partial` on volatile results, accumulate `isFinal` text; on stream end call `analyzer.finalizeAndFinishThroughEndOfInput()`. Audio-format mismatch silently yields nothing, so the converter is mandatory. `LegacySpeechEngine` uses `SFSpeechAudioBufferRecognitionRequest` with `requiresOnDeviceRecognition = true`, `shouldReportPartialResults = true`, appends `chunk.buffer`, calls `endAudio()` at stream end and resolves on `isFinal`.

**Tests:** `SilenceDetectorTests` (no speech → never fires; speech then 1.5 s silence → fires once; short blip below `minSpeech` → never); `DictationPipelineTests` with fake engines and `InMemorySecretStore` + `HistoryStore.inMemory()`: local path writes history with `.inApp`; cloud path uses the key; missing key falls back to local; cloud failure falls back to local; empty transcript throws `.empty` and writes nothing; cleanup receives the config only when `settings.cleanup != .rule`.

**Commit:** `feat(ios): audio capture, on-device + cloud speech engines, dictation pipeline`.

---

## Task 4 — Recorder screen + URL entry point

**Files (create):** `apple/Murmur/Recorder/RecorderViewModel.swift`, `apple/Murmur/Recorder/RecorderView.swift`, `apple/Murmur/Recorder/RecordingIndicator.swift` (pulsing dot driven by level; translucent squiggle while transcribing — port the shapes from `src/components/Hud.tsx`), `apple/Murmur/AppState.swift`, `apple/MurmurTests/RecorderViewModelTests.swift`.
**Modify:** `apple/Murmur/MurmurApp.swift` — `@StateObject var app = AppState()`; `.onOpenURL { app.handle(url) }`; `.fullScreenCover(item: $app.activeDictation) { RecorderView(request: $0) }`.

**Produces:**
```swift
struct DictationRequest: Identifiable, Equatable { let id = UUID(); var session: UUID?; var source: TranscriptSource }   // session != nil ⇢ came from the keyboard via murmur://dictate?session=
final class AppState: ObservableObject {
    @Published var activeDictation: DictationRequest?
    let settings: SettingsStore; let secrets: SecretStore; let history: HistoryStore; let pipeline: DictationPipeline
    func handle(_ url: URL)            // murmur://dictate[?session=UUID] → activeDictation; anything else ignored
    func startInAppDictation()         // source .inApp
}
@MainActor final class RecorderViewModel: ObservableObject {
    enum Phase: Equatable { case starting, recording(level: Float, elapsed: TimeInterval), transcribing(partial: String), done(clean: String, copied: Bool), failed(message: String) }
    @Published var phase: Phase
    init(request: DictationRequest, pipeline: DictationPipeline, audio: AudioSource = AudioCapture(), settings: SettingsStore, clock: @escaping () -> Date = Date.init, maxDuration: TimeInterval = 120)
    func start() async     // requests mic if notDetermined; starts audio; feeds SilenceDetector when settings.autoStopOnSilence; stops at maxDuration; runs pipeline; on success: if settings.copyToClipboard → UIPasteboard.general.string = clean; if request.session != nil → Handoff.writeResult(...)
    func stop()            // user tap
    var showsSwipeBackHint: Bool  // request.session != nil
    var autoDismissAfter: TimeInterval { 8 }
}
```
`RecorderView`: full-screen, system background; `starting` → "Listening…" with the dot; `recording` → dot scaled by level + elapsed timer; tap anywhere stops; `transcribing` → squiggle + partial text; `done` → card with the clean text, "Copied" check when copied, the line "Swipe back to your app — the text will be inserted." when `showsSwipeBackHint`, an explicit Done button, auto-dismiss after 8 s; `failed` → message + "Open Settings" when it is a permission error, else "Try again".

**Tests (`RecorderViewModelTests`, fake `AudioSource` yielding scripted chunks, fake pipeline):** starts in `.recording`; silence auto-stop transitions to `.transcribing` then `.done`; `stop()` mid-recording goes to `.done`; maxDuration cap fires; pipeline `.empty` → `.failed("Didn't catch that.")`; keyboard-sourced request writes a `Handoff` result with the same session; in-app request writes none.

**Commit:** `feat(ios): recorder screen with auto-stop, handoff, and murmur:// entry point`.

---

## Task 5 — Onboarding, Home, Settings, History

**Files (create):** `apple/Murmur/Onboarding/{OnboardingViewModel,OnboardingView}.swift`, `apple/Murmur/Home/{HomeViewModel,HomeView}.swift` (replace the MM0 shell), `apple/Murmur/Settings/{EngineSettingsViewModel,SettingsView,ProviderKeyView}.swift`, `apple/Murmur/History/{HistoryViewModel,HistoryView}.swift`, `apple/Murmur/RootView.swift` (TabView: Home · History · Settings; shows `OnboardingView` until `settings.onboardingComplete`), `apple/Murmur/Components/{StatusChip,Card}.swift`, `apple/MurmurTests/{OnboardingViewModelTests,EngineSettingsViewModelTests,HistoryViewModelTests}.swift`.
**Delete:** the MM0 `HomeView` body and `CoreClientTests` are superseded — keep `CoreClient` (used by settings) and keep one FFI smoke test.

**Produces:**
```swift
@MainActor final class OnboardingViewModel: ObservableObject {
    enum Step: Equatable { case microphone, speech, engine, test }   // keyboard + actionButton steps are appended in MM2
    @Published var step: Step; @Published var mic: PermissionStatus; @Published var speech: PermissionStatus; @Published var localReady: Bool
    init(settings: SettingsStore, permissions: PermissionsProviding = LivePermissions(), speechAvailability: @escaping () async -> Bool = SpeechEngines.isLocalAvailable)
    func requestMic() async; func requestSpeech() async; func choose(stt: SttEngine); func refresh() async; func finish()   // sets settings.onboardingComplete
    var canAdvance: Bool   // mic granted; speech granted OR stt != .local; engine step needs stt ready (local assets or a verified key)
}
protocol PermissionsProviding { func micStatus() -> PermissionStatus; func requestMic() async -> Bool; func speechStatus() -> PermissionStatus; func requestSpeech() async -> Bool }
@MainActor final class EngineSettingsViewModel: ObservableObject {
    @Published var stt: SttEngine; @Published var cleanup: CleanupEngine; @Published var keyPresent: [ProviderId: Bool]; @Published var verifyState: [ProviderId: VerifyState]
    enum VerifyState: Equatable { case idle, verifying, connected, failed(String) }
    init(settings: SettingsStore, secrets: SecretStore, verify: @escaping (CloudConfig) async throws -> Void = MurmurCore.verifyProvider)
    func set(stt:); func set(cleanup:); func saveKey(_ key: String, for: ProviderId) async   // trims, stores, then verifies
    func removeKey(for:); func verify(_ p: ProviderId) async; func openKeyPage(_ p: ProviderId)   // UIApplication.open(keyPageUrl)
    var providersInUse: [ProviderId]   // any provider selected for stt or cleanup, in that order, deduped (mirrors desktop EngineSettings.tsx)
}
@MainActor final class HistoryViewModel: ObservableObject { @Published var query = ""; @Published var items: [Transcript]; init(history: HistoryStore); func reload(); func delete(_ t: Transcript); func copy(_ t: Transcript) }
@MainActor final class HomeViewModel: ObservableObject { @Published var recent: [Transcript]; @Published var mic: PermissionStatus; @Published var speech: PermissionStatus; @Published var engineSummary: String; init(app: AppState); func reload() }
```
UI copy is the desktop's, reused verbatim: engine segment labels "Local · Free", "Groq · Free tier", "OpenAI · Paid"; "Get your API key ↗"; "✓ Connected"; the three per-provider signup steps; error strings come from `CoreError.message`. Settings toggles: "Stop automatically when you pause" (`autoStopOnSilence`), "Copy dictations to the clipboard" with the footer "Universal Clipboard will sync these to your other Apple devices." (`copyToClipboard`).

**Tests:** `OnboardingViewModelTests` (step gating per the `canAdvance` rules with a fake `PermissionsProviding`; choosing groq skips the speech requirement; `finish` flips the setting); `EngineSettingsViewModelTests` (saveKey stores trimmed key then verifies → `.connected`; rejected key → `.failed(message)` and the key stays; removeKey clears both; `providersInUse` ordering); `HistoryViewModelTests` (search filters; delete reloads).

**Commit:** `feat(ios): onboarding, home, settings, and history screens`.

---

## Task 6 — Device verification + docs

**Files (modify):** `apple/README.md` (screens, how to run on a device: select the team in Xcode once, `xcodebuild -destination 'platform=iOS,name=iPhone'` needs the phone unlocked and trusted), `docs/HANDOFF.md` (MM1 section: what works, the device gates below), `docs/superpowers/plans/2026-09-04-murmur-mobile-mm1.md` (tick the tasks).

**Device gates (Matt, with the iPhone plugged in):**
1. Fresh install → onboarding: mic prompt appears and grants; speech prompt appears and grants; Local engine shows ready (or downloads assets once).
2. Home → "Try dictation" → speak one sentence → auto-stops after a pause → cleaned text appears and is in History with source "in-app"; Copy works.
3. Settings → Groq key: "Get your API key ↗" opens Safari; pasting the key shows "✓ Connected"; switching STT to Groq and dictating works; airplane mode + Groq → falls back to local and still returns text.
4. Safari address bar: `murmur://dictate?session=00000000-0000-0000-0000-000000000001` opens the recorder directly, records, shows the "Swipe back" hint, and the clipboard holds the text.
5. Force-quit during recording → relaunch offers nothing broken (the crash-safety "finish last dictation" feature is deferred to MM2 with the keyboard).

**Commit:** `docs(ios): MM1 handoff and device checklist`.

---

## Review checklist (Fable, after each task)
1. No key value ever reaches `print`, `os_log`, UserDefaults, history, or a view (grep for `apiKey` outside `Keychain.swift`, `EngineSettingsViewModel.swift`, `DictationPipeline.swift`, `CloudSpeechEngine.swift`).
2. Every view model has a test target file and every test uses fakes, not the live mic/network.
3. `project.yml` changes are mirrored in the committed pbxproj (`xcodegen generate` leaves `git status` clean).
4. History insert happens before clipboard/handoff in `DictationPipeline.run` / `RecorderViewModel`.
5. Signatures match this plan's **Produces** blocks exactly.
