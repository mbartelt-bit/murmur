import AppIntents
import Foundation
import MurmurSharedBase

/// "Dictate with Murmur" — the trigger that needs no keyboard.
///
/// The Action Button, Back Tap, Siri, a Shortcut, and the iOS 18 Control Center button
/// (``DictateControl`` in the MurmurControls extension) all run this one intent. None of them
/// launch from the keyboard, so none of them go anywhere near App Review guideline 4.4.1 —
/// which is exactly why the spec (§2 constraint 6, §6.3) wants this path to be first-class.
///
/// `openAppWhenRun` does the actual work of getting Murmur on screen; ``perform()`` only
/// leaves a note in the App Group saying *why* it is being opened. The app reads that note in
/// `AppState.consumeLaunchFlag(defaults:)` the moment its scene goes active and puts the
/// recorder up with `session = Handoff.intentSession`, so a Murmur keyboard that is active in
/// the host app picks the finished text up on its next appearance the same way it picks up its
/// own round trips.
///
/// The flag, not a `Handoff` pending record, is what carries the launch: the intent process is
/// short-lived and may be running in the background well before the app is up, and a plain
/// string in the shared defaults survives that gap with nothing to expire or race.
public struct DictateIntent: AppIntent {
    /// The App Group defaults key the intent sets and ``AppState`` clears.
    public static let launchFlagKey = "launch.dictate"

    public static let title: LocalizedStringResource = "Dictate with Murmur"

    public static let description = IntentDescription(
        "Start a Murmur dictation. The text is copied to the clipboard and inserted if the Murmur keyboard is active."
    )

    /// Murmur has to be foregrounded: an extension — and an intent process — cannot record
    /// (spec §2 constraint 1), so the microphone only ever runs in the containing app.
    public static let openAppWhenRun = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        AppGroup.defaults.set("action-button", forKey: Self.launchFlagKey)
        return .result()
    }
}
