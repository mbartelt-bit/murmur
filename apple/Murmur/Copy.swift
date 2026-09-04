import Foundation
import MurmurShared

/// Every user-facing string in the app, in one place.
///
/// Two reasons it is a single enum rather than strings spread through the views: the MM2
/// keyboard extension has to say exactly what the app says (a user who reads "Local · Free"
/// here must not read "On-device" there), and the lines that came from the desktop —
/// `src/components/EngineSettings.tsx` — are copied verbatim so the Mac and the phone stay
/// one product. Anything marked *desktop* below must not be reworded on its own.
enum Copy {
    // MARK: - App

    static let appName = "Murmur"
    static let openSettings = "Open Settings"
    static let copied = "Copied"
    static let continueLabel = "Continue"

    // MARK: - Tabs

    static let homeTab = "Home"
    static let historyTab = "History"
    static let settingsTab = "Settings"

    // MARK: - Onboarding

    static let welcomeTitle = "Welcome to Murmur"
    static let welcomeSubtitle = "Speak, and Murmur writes it down — cleaned up, on your phone."

    static let micStepTitle = "Microphone"
    static let micStepBody = "Murmur needs the microphone to hear you. Nothing is recorded until you start a dictation."
    static let micAllow = "Allow microphone"
    static let permissionPending = "Not allowed yet."
    static let micGranted = "Microphone allowed."
    static let micDenied = "Microphone access is off. Turn it on in Settings to dictate."

    static let speechStepTitle = "Speech recognition"
    static let speechStepBody = "The free engine transcribes with Apple speech recognition on this device. Nothing leaves your phone."
    static let speechAllow = "Allow speech recognition"
    static let speechGranted = "Speech recognition allowed."
    static let speechDenied = "Speech recognition is off. Turn it on in Settings, or pick Groq or OpenAI on the next step."

    static let engineStepTitle = "Choose an engine"
    /// *desktop* — the steering line under the transcription segmented control.
    static let engineStepBody = "Local is free & private. Groq is free in the cloud (no card). OpenAI is paid but most accurate."
    static let preparingLocal = "Preparing on-device speech…"
    static let localReady = "On-device speech is ready."
    static let localUnavailable = "On-device speech isn't available for your language. Pick Groq or OpenAI."

    static let keyboardStepTitle = "Turn on the Murmur keyboard"
    static let keyboardStepBody = "The keyboard is how Murmur types into every other app. Add it once, in Settings."
    /// The path Settings actually takes — there is no public deep link past Murmur's own pane.
    static let keyboardStepPath = "Settings → General → Keyboard → Keyboards → Add New Keyboard → Murmur"
    static let keyboardFullAccessLine = "Then tap Murmur → Allow Full Access — so the keyboard can read your dictation from Murmur."
    static let keyboardCheckLine = "Check: open any app, switch to Murmur once, then come back."
    static let keyboardStepDone = "The Murmur keyboard is on."
    static let keyboardStepWaiting = "Not added yet — Murmur keeps checking."
    static let fullAccessOn = "Full Access is on."
    static let fullAccessOff = "Full Access is off. The mic key will explain it again."
    static let fullAccessUnknown = "Full Access hasn't been checked yet."
    static let later = "Later"

    static let triggersStepTitle = "Dictate without the keyboard"
    static let triggersStepBody = "Two other ways to start: both open Murmur, listen, and put the text on your clipboard."
    static let controlCenterTitle = "Control Center"
    static let controlCenterCopy = "Add the Murmur button to Control Center: swipe down, tap +, search Murmur."
    static let actionButtonTitle = "Action Button"
    static let actionButtonCopy = "Settings → Action Button → Shortcut → Dictate with Murmur."
    static let testIt = "Test it"

    static let testStepTitle = "Try it"
    static let testStepBody = "Tap the button and say one sentence, then stop talking. Murmur cleans it up and saves it to History."
    static let testStepDone = "That's it. Your dictation is in History."
    static let finish = "Finish"
    static let skipForNow = "Skip for now"

    // MARK: - Engines (desktop wording, cost badge folded into the label)

    static func sttLabel(_ engine: SttEngine) -> String {
        switch engine {
        case .local: return "Local · Free"
        case .groq: return "Groq · Free tier"
        case .openai: return "OpenAI · Paid"
        }
    }

    static func cleanupLabel(_ engine: CleanupEngine) -> String {
        switch engine {
        case .rule: return "Rules · Free"
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        }
    }

    // MARK: - Provider keys (desktop wording)

    static func connectProvider(_ provider: ProviderId) -> String { "Connect \(provider.displayName)" }
    static func keyFieldPlaceholder(_ provider: ProviderId) -> String { "\(provider.displayName) API key" }
    static let getApiKey = "Get your API key ↗"
    static let connect = "Connect"
    static let connecting = "Connecting…"
    static let verify = "Verify"
    static let verifying = "Verifying…"
    static let connected = "✓ Connected"
    static let keySaved = "Key saved"
    static let removeKey = "Remove key"
    static let addKeyFirst = "Add your key first."

    // MARK: - Home

    static let tryDictation = "Try dictation"
    static let recentTitle = "Recent"
    static let noDictationsYet = "No dictations yet. Tap Try dictation to make your first one."
    static let historyUnavailable = "History unavailable this session"
    static let tapToCopy = "Tap a dictation to copy it."

    static let chipMic = "Microphone"
    static let chipSpeech = "Speech"
    static let chipEngine = "Engine"
    static let chipAllowed = "Allowed"
    static let chipTapToAllow = "Tap to allow"
    static let chipTapToFix = "Tap to fix"

    // MARK: - Home · finish the last dictation (spec §9, "App killed mid-recording")

    static let recoveryTitle = "Finish last dictation?"
    /// `duration` comes from ``recoveryDuration(_:)`` — "about 12 s".
    static func recoveryBody(_ duration: String) -> String {
        String(format: "Murmur was closed while recording %@ of audio.", duration)
    }

    /// Deliberately vague: the journal is written every two seconds, so the number is only
    /// ever approximately what the user said, and "about" is the honest way to say so.
    static func recoveryDuration(_ seconds: TimeInterval) -> String {
        "about \(Int(seconds.rounded())) s"
    }

    /// The same words as the onboarding and keyboard buttons, kept separate so either can be
    /// reworded without dragging the other with it.
    static let recoveryFinish = "Finish"
    static let recoveryDiscard = "Discard"
    static let recoveryFailed = "Couldn't finish it — the audio was too short or the engine failed."

    static let chipKeyboard = "Keyboard"
    static let chipFullAccess = "Full Access"
    static let chipActionButton = "Action Button"
    static let chipOn = "On"
    static let chipOff = "Off"
    static let chipUnknown = "Unknown"
    static let chipSetUp = "Set up"

    /// The engine chip's second line: which engine, and whether it can actually run.
    static func engineSummary(stt: SttEngine, keyPresent: Bool) -> String {
        switch stt {
        case .local: return "Local · on device"
        case .groq, .openai: return keyPresent ? "\(sttName(stt)) · connected" : "\(sttName(stt)) · no key"
        }
    }

    static func sttName(_ engine: SttEngine) -> String {
        switch engine {
        case .local: return "Local"
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        }
    }

    // MARK: - Settings

    static let transcriptionSection = "Transcription"
    static let cleanupSection = "Cleanup"
    static let autoStopToggle = "Stop automatically when you pause"
    static let clipboardToggle = "Copy dictations to the clipboard"
    static let clipboardFooter = "Universal Clipboard will sync these to your other Apple devices."
    static let aboutSection = "About"
    static let versionRow = "Version"

    // MARK: - History

    static let searchPlaceholder = "Search dictations"
    static let historyEmpty = "No dictations yet."
    static let historyNoMatches = "No matches."
    static let delete = "Delete"
    static let showRaw = "Show raw"
    static let hideRaw = "Hide raw"

    static func sourceLabel(_ source: TranscriptSource) -> String {
        switch source {
        case .inApp: return "In app"
        case .keyboard: return "Keyboard"
        case .actionButton: return "Action Button"
        }
    }
}
