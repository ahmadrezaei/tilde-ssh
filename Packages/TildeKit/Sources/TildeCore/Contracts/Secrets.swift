import Foundation

// MARK: - Secrets (KeychainSecretStore; mock: InMemorySecretStore)

/// The kind of secret; the raw value is the `<kind>` prefix of the Keychain account (`pw:<uuid>`).
public enum SecretKind: String, Sendable {
    case password = "pw"
    case privateKey = "key"
    case keyPassphrase = "kpp"
}

/// A reference to one secret. SwiftData records hold only the `id`; the data lives in the Keychain.
public struct SecretRef: Hashable, Sendable {
    public let kind: SecretKind
    public let id: UUID

    public init(kind: SecretKind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

/// Keychain-backed storage for passwords and private keys.
public protocol SecretStore: Sendable {
    /// Stores (or replaces) a secret. `label` is the human-readable Keychain label.
    func write(_ data: Data, for ref: SecretRef, label: String, synchronizable: Bool) throws
    /// Returns the secret, or `nil` if it is not (yet) on this device.
    func read(_ ref: SecretRef) throws -> Data?
    func delete(_ ref: SecretRef) throws
    func allRefs() throws -> [SecretRef]
}
