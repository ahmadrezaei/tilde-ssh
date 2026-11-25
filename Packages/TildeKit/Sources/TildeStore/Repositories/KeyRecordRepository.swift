import Foundation
import SwiftData
import TildeCore

/// CRUD for `SSHKeyRecord` (metadata only; private material lives in the Keychain, written by the security module's
/// `SecretStore`).
@MainActor
public final class KeyRecordRepository {
    public let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    /// All keys, alphabetical by name.
    public func all() throws -> [SSHKeyRecord] {
        try context.fetch(FetchDescriptor<SSHKeyRecord>()).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func record(id: UUID) throws -> SSHKeyRecord? {
        var descriptor = FetchDescriptor<SSHKeyRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The key whose Keychain item is `key:<secretID>`.
    public func record(privateSecretID secretID: UUID) throws -> SSHKeyRecord? {
        var descriptor = FetchDescriptor<SSHKeyRecord>(predicate: #Predicate { $0.privateSecretID == secretID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Stores key metadata. The caller has already written the private key to the `SecretStore`
    /// under `record.privateSecretRef`.
    @discardableResult
    public func add(_ record: SSHKeyRecord, deviceName: String? = nil) throws -> SSHKeyRecord {
        guard !record.publicKeyOpenSSH.isEmpty else { throw StoreError.invalidValue("A key needs a public key.") }
        if let deviceName, record.originDeviceName.isEmpty { record.originDeviceName = deviceName }
        record.updatedAt = .now
        context.insert(record)
        try context.save()
        return record
    }

    public func rename(_ record: SSHKeyRecord, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidValue("A key needs a name.") }
        record.name = trimmed
        record.updatedAt = .now
        try context.save()
    }

    /// How many servers use `record`.
    public func usageCount(of record: SSHKeyRecord) -> Int { record.servers?.count ?? 0 }

    /// Deletes the key record. Blocked (`StoreError.keyInUse`) while servers reference it, unless
    /// `replacement` is given, in which case those servers are moved to it first.
    ///
    /// - Returns: the Keychain reference of the private key, which the caller deletes in the same user action.
    @discardableResult
    public func delete(_ record: SSHKeyRecord, reassigningServersTo replacement: SSHKeyRecord? = nil) throws -> SecretRef {
        let users = record.servers ?? []
        if !users.isEmpty {
            guard let replacement, replacement.id != record.id else { throw StoreError.keyInUse(serverCount: users.count) }
            for server in users {
                server.key = replacement
                server.updatedAt = .now
            }
        }
        let ref = record.privateSecretRef
        context.delete(record)
        try context.save()
        return ref
    }
}
