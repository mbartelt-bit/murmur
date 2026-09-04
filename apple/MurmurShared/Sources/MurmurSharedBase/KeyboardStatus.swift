import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What the containing app can learn about its own keyboard extension — and the one place
/// that knows the heartbeat the extension leaves behind.
///
/// iOS answers none of these questions directly. There is no API for "is my keyboard
/// enabled", none for "does it have Full Access", and no public deep link to either pane of
/// Settings. So:
///
/// - **Enabled** is read from `AppleKeyboards` in `UserDefaults.standard`, the documented,
///   app-readable list of the keyboards the user has added.
/// - **Full Access** is read from a heartbeat the extension writes on every appearance
///   (``fullAccessKey`` / ``lastSeenKey``, written by `KeyboardController.viewWillAppear`).
///   That makes it a *memory*, not a fact, so it expires: a heartbeat older than
///   ``heartbeatValidity`` is reported as unknown rather than as a stale yes.
/// - **The Action Button** is a hardware question, answered from the model identifier.
///
/// This lives in `MurmurSharedBase` so the extension can read the same constants the app
/// does without either side depending on the other.
public enum KeyboardStatus {
    /// Must match `PRODUCT_BUNDLE_IDENTIFIER` for the `MurmurKeyboard` target in
    /// `apple/project.yml`.
    public static let extensionBundleId = "com.murmur.app.keyboard"

    /// The App Group keys the keyboard's heartbeat uses. The extension writes them; the app
    /// only ever reads them.
    public static let fullAccessKey = "keyboard.fullAccess"
    public static let lastSeenKey = "keyboard.lastSeen"

    /// How long a heartbeat is believed. A week is long enough that a user who set Murmur up
    /// once is not nagged for it again, and short enough that "Full Access is on" cannot
    /// survive a reinstall or a settings change made months ago.
    public static let heartbeatValidity: TimeInterval = 7 * 24 * 60 * 60

    /// The key iOS keeps the user's keyboard list under, readable from any app's standard
    /// defaults.
    private static let appleKeyboardsKey = "AppleKeyboards"

    // MARK: - Enabled

    /// Whether the user has added the Murmur keyboard in Settings.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: appleKeyboardsKey) as? [String])?.contains(extensionBundleId) == true
    }

    // MARK: - Full Access

    /// `true` / `false` from the keyboard's last heartbeat, or `nil` when there is no fresh
    /// one — which is the honest answer before the keyboard has ever appeared, and the reason
    /// the onboarding step says "open any app, switch to Murmur once, then come back".
    public static func hasFullAccess(appGroup: UserDefaults = AppGroup.defaults, now: Date = Date()) -> Bool? {
        guard let lastSeen = appGroup.object(forKey: lastSeenKey) as? Date else { return nil }
        guard now.timeIntervalSince(lastSeen) <= heartbeatValidity else { return nil }
        return appGroup.object(forKey: fullAccessKey) as? Bool
    }

    // MARK: - Action Button

    /// Whether this iPhone has an Action Button, from its model identifier.
    ///
    /// `iPhone16,1` and `iPhone16,2` are the 15 Pro and 15 Pro Max, the two models in the
    /// first generation that shipped one; every iPhone from the 16 family on (`iPhone17,x`
    /// and later) has it across the whole line. Anything that is not an iPhone — an iPad, a
    /// Mac running the iPad app — has none.
    public static func hasActionButton(modelIdentifier: String) -> Bool {
        guard modelIdentifier.hasPrefix("iPhone") else { return false }
        let parts = modelIdentifier.dropFirst("iPhone".count).split(separator: ",")
        guard let major = parts.first.flatMap({ Int($0) }) else { return false }
        if major >= 17 { return true }
        guard major == 16, parts.count > 1, let minor = Int(parts[1]) else { return false }
        return minor == 1 || minor == 2
    }

    /// This device's model identifier, e.g. `iPhone17,3`. On the simulator the host's
    /// `utsname` is the Mac's, so the simulated device is read from the environment instead.
    public static var modelIdentifier: String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return simulated
        }
        #endif
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// ``hasActionButton(modelIdentifier:)`` for the device this is running on.
    public static var hasActionButton: Bool { hasActionButton(modelIdentifier: modelIdentifier) }

    // MARK: - Settings

    #if canImport(UIKit)
    /// Opens Settings at Murmur's own pane — the deepest public link iOS offers. There is no
    /// URL for the Keyboards list or for the Action Button screen, which is why every caller
    /// pairs this with the written path.
    ///
    /// Unavailable in an app extension by construction: the keyboard reaches Settings through
    /// `KeyboardController.openSettings()` and the responder chain instead.
    @available(iOSApplicationExtension, unavailable)
    @MainActor
    public static func openKeyboardSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif
}
