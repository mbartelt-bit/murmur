import AppIntents
import MurmurIntents

/// The one shortcut Murmur donates to the system, so "Dictate with Murmur" shows up in
/// Shortcuts, in Siri, and in the Action Button and Back Tap pickers without the user having
/// to build anything (spec §6.3).
///
/// Two phrases, both containing `\(.applicationName)` because App Intents requires the app
/// name in every phrase: the natural one and the short one people actually say.
///
/// **This has to live in the app target, not in MurmurIntents next to the intent it points
/// at.** `appintentsmetadataprocessor` merges *actions* out of linked packages into the app's
/// `Metadata.appintents` — `DictateIntent` arrives that way — but it takes `autoShortcuts`
/// only from the app module's own sources: with the provider in the package, the package's own
/// bundle carried both phrases and the app's merged bundle came out with `autoShortcuts: []`,
/// i.e. no Siri phrase and nothing in the Action Button picker.
struct MurmurShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DictateIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Start \(.applicationName)"
            ],
            shortTitle: "Dictate",
            systemImageName: "mic.fill"
        )
    }
}
