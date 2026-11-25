import Foundation
import Security
import TildeCore

/// A failed Keychain call. Carries only the `OSStatus`: never a label, account or secret.
public struct KeychainError: Error, Equatable, Sendable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) { self.status = status }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// `SecretStore` backed by generic-password Keychain items (docs/DESIGN.md section 6.2).
///
/// - Service `app.tildessh.secret`, account `<kind>:<uuid>` (`pw`, `key`, `kpp`).
/// - Synchronizable items use `kSecAttrAccessibleAfterFirstUnlock` and travel through iCloud Keychain;
///   "this device only" items use `...AfterFirstUnlockThisDeviceOnly`.
/// - Items live in the shared access group from the `TildeKeychainAccessGroup` Info.plist key. Unsigned builds
///   (where `$(AppIdentifierPrefix)` expands to nothing) fall back to the app's default group.
/// - On macOS the data-protection (iOS-style) keychain is used, which iCloud sync requires.
public struct KeychainSecretStore: SecretStore {
    public static let defaultService = "app.tildessh.secret"

    private let service: String
    private let accessGroup: String?
    private let useDataProtectionKeychain: Bool

    /// `true` when this process can use the data-protection keychain. Always `true` on iOS. On macOS it needs the
    /// `keychain-access-groups` entitlement, which unsigned and ad-hoc builds lack; they use the file keychain instead
    /// (works, but cannot sync through iCloud).
    public static var dataProtectionKeychainIsAvailable: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
        #else
        return true
        #endif
    }

    /// - Parameters:
    ///   - service: Keychain service name; override only in tests.
    ///   - accessGroup: explicit access group, or `nil` for none. Defaults to the Info.plist value (if signed).
    ///   - useDataProtectionKeychain: macOS only. Defaults to whether the process has the entitlement the
    ///     data-protection keychain needs, so unsigned builds fall back to the file keychain instead of failing with
    ///     `errSecMissingEntitlement`.
    public init(
        service: String = KeychainSecretStore.defaultService,
        accessGroup: String? = KeychainSecretStore.accessGroupFromInfoPlist(),
        useDataProtectionKeychain: Bool = KeychainSecretStore.dataProtectionKeychainIsAvailable
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.useDataProtectionKeychain = useDataProtectionKeychain
    }

    // MARK: Access group

    /// Reads `TildeKeychainAccessGroup` from the main bundle. Returns `nil` when it is missing, still an unexpanded
    /// build setting, or lacks the 10-character team prefix (unsigned builds).
    public static func accessGroupFromInfoPlist(bundle: Bundle = .main) -> String? {
        validatedAccessGroup(bundle.object(forInfoDictionaryKey: "TildeKeychainAccessGroup") as? String)
    }

    /// `nil` unless `value` looks like `TEAMID.some.group`.
    static func validatedAccessGroup(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, !value.contains("$(") else { return nil }
        let pieces = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count == 10, pieces[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }), !pieces[1].isEmpty else {
            return nil
        }
        return value
    }

    // MARK: SecretStore

    public func write(_ data: Data, for ref: SecretRef, label: String, synchronizable: Bool) throws {
        // The nil UUID is reserved for "nothing was saved" (see `SecretRef.isUnsavedSentinel`).
        guard !ref.isUnsavedSentinel else { throw KeychainError(status: errSecParam) }
        let accessible = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let query = itemQuery(for: ref, synchronizable: synchronizable)
        let updates: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrLabel: label,
            kSecAttrAccessible: accessible,
        ]

        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes.merge(updates) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Someone (another device's sync, a concurrent write) added it between our update and add.
                status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
            }
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }

        // If the sync flag changed, remove the item stored under the opposite flag so a stale copy cannot linger.
        // (The legacy macOS keychain used by unsigned test builds cannot hold synchronizable items and answers
        // "missing entitlement" when asked about them; there is nothing to clean up in that case.)
        let stale = SecItemDelete(itemQuery(for: ref, synchronizable: !synchronizable) as CFDictionary)
        guard stale == errSecSuccess || stale == errSecItemNotFound || stale == errSecMissingEntitlement else {
            throw KeychainError(status: stale)
        }
    }

    public func read(_ ref: SecretRef) throws -> Data? {
        var query = itemQuery(for: ref, synchronizable: nil)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func delete(_ ref: SecretRef) throws {
        let status = SecItemDelete(itemQuery(for: ref, synchronizable: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    public func allRefs() throws -> [SecretRef] {
        var query = baseQuery()
        query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let rows = result as? [[String: Any]] ?? []
            var seen = Set<SecretRef>()
            var refs: [SecretRef] = []
            for row in rows {
                guard let account = row[kSecAttrAccount as String] as? String, let ref = Self.parse(account: account), seen.insert(ref).inserted else { continue }
                refs.append(ref)
            }
            return refs
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError(status: status)
        }
    }

    // MARK: Query helpers

    static func account(for ref: SecretRef) -> String { "\(ref.kind.rawValue):\(ref.id.uuidString)" }

    static func parse(account: String) -> SecretRef? {
        let pieces = account.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, let kind = SecretKind(rawValue: String(pieces[0])), let id = UUID(uuidString: String(pieces[1])) else { return nil }
        return SecretRef(kind: kind, id: id)
    }

    private func baseQuery() -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        #if os(macOS)
        if useDataProtectionKeychain { query[kSecUseDataProtectionKeychain] = true }
        #endif
        return query
    }

    /// Query for one item. `synchronizable == nil` matches the item whichever way it was stored.
    private func itemQuery(for ref: SecretRef, synchronizable: Bool?) -> [CFString: Any] {
        var query = baseQuery()
        query[kSecAttrAccount] = Self.account(for: ref)
        query[kSecAttrSynchronizable] = synchronizable.map { $0 as CFBoolean } ?? kSecAttrSynchronizableAny
        return query
    }
}
