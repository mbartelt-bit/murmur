import MurmurCore
import MurmurSharedBase

/// The one thing that kept ``ProviderId`` — and with it ``Settings``, ``AppGroup`` and
/// ``Handoff`` — tied to the Rust core.
///
/// It lives here, in `MurmurShared`, rather than next to the enum in `MurmurSharedBase`, so
/// the keyboard extension can read the settings blob and the hand-off without linking
/// `MurmurCore` at all (design spec §2 constraint 5: a keyboard extension has ~50–70 MB and
/// no business loading a transcription engine). Every existing call site — `CoreClient`,
/// `DictationPipeline` — sees it unchanged because they all `import MurmurShared`.
public extension ProviderId {
    /// The matching `murmur-core` provider for a ``MurmurCore/CloudConfig``.
    var core: MurmurCore.Provider {
        switch self {
        case .groq: return .groq
        case .openai: return .openAi
        }
    }
}
