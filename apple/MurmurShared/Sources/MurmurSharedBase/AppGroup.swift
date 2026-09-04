import Foundation

/// The one shared sandbox the app, the keyboard extension, and the App Intent all read.
///
/// Everything durable that is *not* a secret lives here: the settings blob, the dictation
/// handoff, and the SQLite history file. Secrets go to ``Keychain`` instead — see §10 of the
/// design spec, which forbids keys in the App Group defaults.
public enum AppGroup {
    /// Must match `com.apple.security.application-groups` in `Murmur/Murmur.entitlements`.
    public static let id = "group.com.murmur.app"

    /// Shared `UserDefaults`. Resolved once; every caller gets the same instance.
    public static var defaults: UserDefaults { sharedDefaults }

    /// Shared container directory (where `murmur.sqlite` lives from Task 2 on).
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` returns `nil` when the process is
    /// not entitled for the group, so the temporary directory is the last-ditch fallback that
    /// keeps a misconfigured build usable instead of crashing.
    public static var containerURL: URL { sharedContainerURL }

    private static let sharedDefaults: UserDefaults = {
        if let suite = UserDefaults(suiteName: id) { return suite }
        #if DEBUG
        // Only reachable from a unit-test host that lacks the App Group entitlement.
        return .standard
        #else
        preconditionFailure("App Group \(id) is unavailable — check Murmur.entitlements.")
        #endif
    }()

    private static let sharedContainerURL: URL = {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? FileManager.default.temporaryDirectory
    }()
}
