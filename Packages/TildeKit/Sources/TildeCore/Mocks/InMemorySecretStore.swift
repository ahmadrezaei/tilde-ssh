import Foundation
import Synchronization

/// A `SecretStore` kept in memory. Not persisted; for previews and tests.
public final class InMemorySecretStore: SecretStore {
    public struct Entry: Sendable, Equatable {
        public var data: Data
        public var label: String
        public var synchronizable: Bool
    }
    private let storage = Mutex<[SecretRef: Entry]>([:])

    public init() {}

    public func write(_ data: Data, for ref: SecretRef, label: String, synchronizable: Bool) throws {
        storage.withLock { $0[ref] = Entry(data: data, label: label, synchronizable: synchronizable) }
    }

    public func read(_ ref: SecretRef) throws -> Data? { storage.withLock { $0[ref]?.data } }

    public func delete(_ ref: SecretRef) throws { storage.withLock { _ = $0.removeValue(forKey: ref) } }

    public func allRefs() throws -> [SecretRef] { storage.withLock { Array($0.keys) } }

    /// Inspect the stored label / sync flag in tests.
    public func entry(for ref: SecretRef) -> Entry? { storage.withLock { $0[ref] } }
}
