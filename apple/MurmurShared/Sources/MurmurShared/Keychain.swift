import Foundation
import Security

/// Where API keys live. Deliberately tiny: get, set, delete, and nothing that could log a value.
///
/// Keys never leave this abstraction except to be handed straight to a `murmur-core` call
/// (design spec §10). Nothing here prints, logs, or copies a value anywhere else.
public protocol SecretStore {
    func get(_ account: String) throws -> String?
    func set(_ account: String, _ value: String) throws
    func delete(_ account: String) throws
}

/// Failures coming back from the Security framework. The `OSStatus` is kept for diagnosis;
/// the secret itself is never part of an error.
public enum KeychainError: Error, Equatable {
    /// `SecItem*` returned something other than `errSecSuccess` / `errSecItemNotFound`.
    case unhandled(status: OSStatus)
    /// A stored item held bytes that are not UTF-8 — it was not written by us.
    case malformedData
}

/// The real Keychain, using generic-password items keyed by `service` + `account`.
///
/// Account names are the desktop's (`groq_api_key`, `openai_api_key`) so a future sync sees
/// the same items. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` means the keyboard
/// extension can read a key in the background after the first unlock, and the item never
/// leaves the device in a backup.
public struct Keychain: SecretStore {
    public let service: String
    public let accessGroup: String?

    public init(service: String = "com.murmur.app", accessGroup: String? = Keychain.defaultAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// The shared access group `<team prefix>com.murmur.app`, or `nil` when it cannot be
    /// determined — in which case items land in the app's own default group.
    ///
    /// On macOS you would read `keychain-access-groups` off the running task with
    /// `SecTaskCopyValueForEntitlement`; that API does not exist on iOS. Instead the app's
    /// Info.plist carries `AppIdentifierPrefix` (set to `$(AppIdentifierPrefix)` in
    /// `project.yml`), which Xcode expands from `DEVELOPMENT_TEAM` to `TEAMID.` — on the
    /// **simulator** too, verified by ``KeychainTests``, which is why the simulator tests
    /// exercise the same access group the device uses. (The simulator keychain does not
    /// enforce access groups, so no provisioning profile is needed for them to pass.)
    ///
    /// A build with no team set leaves the value empty or as the unexpanded literal; both are
    /// rejected below and items then land in the app's own default group.
    public static let defaultAccessGroup: String? = {
        guard let prefix = Bundle.main.infoDictionary?["AppIdentifierPrefix"] as? String,
              !prefix.isEmpty,
              !prefix.contains("$(")
        else { return nil }
        return prefix + "com.murmur.app"
    }()

    public func get(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.malformedData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandled(status: status)
        }
    }

    public func set(_ account: String, _ value: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account)

        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError.unhandled(status: updated) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.unhandled(status: added) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status: status)
        }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

/// A ``SecretStore`` that keeps values in memory only — for unit tests and SwiftUI previews,
/// so neither ever touches the device keychain.
public final class InMemorySecretStore: SecretStore {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func get(_ account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    public func set(_ account: String, _ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = value
    }

    public func delete(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[account] = nil
    }
}
