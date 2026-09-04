import Combine
import Foundation
import MurmurShared

/// One dictation the app has been asked to run.
///
/// `session` is the keyboard's round-trip id: when it is set, the finished text is written
/// back to the App Group for the extension to insert (design spec §8); when it is `nil` the
/// dictation started inside Murmur and the text only goes to history and the clipboard.
///
/// `id` is fresh per request on purpose — presenting a second `murmur://dictate` while the
/// recorder is already up must tear the old screen down and build a new one, and SwiftUI
/// decides that by identity.
struct DictationRequest: Identifiable, Equatable {
    let id = UUID()
    var session: UUID?
    var source: TranscriptSource

    init(session: UUID? = nil, source: TranscriptSource) {
        self.session = session
        self.source = source
    }
}

/// The app's live objects, built once at launch, plus the one piece of navigation state that
/// every entry point drives: whether a dictation is on screen.
///
/// The URL handler is here rather than in the view so it stays testable: `murmur://dictate`
/// arrives from the MM2 keyboard extension, from the Action Button intent, and from Safari
/// during device QA, and all three have to produce exactly the same request.
final class AppState: ObservableObject {
    /// The recorder is presented as a full-screen cover over whatever screen the app was on.
    @Published var activeDictation: DictationRequest?

    let settings: SettingsStore
    let secrets: SecretStore
    let history: HistoryStore
    let pipeline: DictationPipeline

    /// `true` when the history database could not be opened and this run is using a throwaway
    /// in-memory one instead: dictation still works, nothing is kept. The history screen reads
    /// it to explain itself rather than showing an empty list.
    let historyUnavailable: Bool

    init(
        settings: SettingsStore,
        secrets: SecretStore,
        history: HistoryStore,
        pipeline: DictationPipeline,
        historyUnavailable: Bool = false
    ) {
        self.settings = settings
        self.secrets = secrets
        self.history = history
        self.pipeline = pipeline
        self.historyUnavailable = historyUnavailable
    }

    /// The real app: shared settings, the Keychain, and the App Group database.
    convenience init() {
        let settings = SettingsStore()
        let secrets = Keychain()
        let (history, unavailable) = Self.openHistory()
        self.init(
            settings: settings,
            secrets: secrets,
            history: history,
            pipeline: DictationPipeline(settings: settings, secrets: secrets, history: history),
            historyUnavailable: unavailable
        )
    }

    // MARK: - Entry points

    /// Handles `murmur://dictate[?session=UUID]`. Anything else — another scheme, another
    /// host, a session that is not a UUID — is ignored without a word, because these URLs are
    /// machine-written and a malformed one is a bug on the other side, not something to
    /// interrupt the user about.
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "murmur" else { return }

        // `murmur://dictate` puts it in the host; `murmur:dictate` puts it in the path.
        let target = url.host?.lowercased() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard target == "dictate" else { return }

        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "session" }?
            .value

        guard let raw else {
            // No session: nobody is waiting for the text, so this is an in-app dictation.
            activeDictation = DictationRequest(source: .inApp)
            return
        }
        guard let session = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        activeDictation = DictationRequest(session: session, source: .keyboard)
    }

    /// The in-app "Try dictation" path: same recorder, no handoff.
    func startInAppDictation() {
        activeDictation = DictationRequest(source: .inApp)
    }

    // MARK: - History

    /// The App Group database, or an in-memory stand-in when it cannot be opened (a corrupt
    /// or unreadable file). Losing history is bad; refusing to launch is worse, and the
    /// dictation path itself does not need the file to work.
    private static func openHistory() -> (HistoryStore, Bool) {
        if let store = try? HistoryStore(url: HistoryStore.defaultURL) { return (store, false) }
        // An in-memory SQLite database has nothing left to fail on; if this throws the
        // process has no working storage at all.
        return (try! HistoryStore.inMemory(), true)
    }
}
