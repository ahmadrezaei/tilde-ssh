import Foundation
import Security
import Testing
import TildeCore
@testable import TildeSecurity

/// `SecretStore` behaviour, shared by the in-memory mock and the Keychain implementation.
@Suite struct SecretStoreTests {
    // MARK: Keychain naming

    @Test func accountNamingFollowsTheScheme() {
        let id = UUID(uuidString: "5F3E0F2A-7A55-4D4D-8E6A-0C3E6F0B1A11")!
        #expect(KeychainSecretStore.account(for: SecretRef(kind: .password, id: id)) == "pw:5F3E0F2A-7A55-4D4D-8E6A-0C3E6F0B1A11")
        #expect(KeychainSecretStore.account(for: SecretRef(kind: .privateKey, id: id)).hasPrefix("key:"))
        #expect(KeychainSecretStore.account(for: SecretRef(kind: .keyPassphrase, id: id)).hasPrefix("kpp:"))
        for kind in [SecretKind.password, .privateKey, .keyPassphrase] {
            let ref = SecretRef(kind: kind, id: UUID())
            #expect(KeychainSecretStore.parse(account: KeychainSecretStore.account(for: ref)) == ref)
        }
        #expect(KeychainSecretStore.parse(account: "nonsense") == nil)
        #expect(KeychainSecretStore.parse(account: "xx:\(id.uuidString)") == nil)
        #expect(KeychainSecretStore.parse(account: "pw:not-a-uuid") == nil)
        #expect(KeychainSecretStore.defaultService == "app.tildessh.secret")
    }

    @Test func unsignedBuildsHaveNoAccessGroup() {
        // Unsigned: $(AppIdentifierPrefix) expands to nothing, or is not expanded at all.
        #expect(KeychainSecretStore.validatedAccessGroup(nil) == nil)
        #expect(KeychainSecretStore.validatedAccessGroup("") == nil)
        #expect(KeychainSecretStore.validatedAccessGroup("app.tildessh.shared") == nil)
        #expect(KeychainSecretStore.validatedAccessGroup("$(AppIdentifierPrefix)app.tildessh.shared") == nil)
        #expect(KeychainSecretStore.validatedAccessGroup("ABCDE12345.") == nil)
        // Signed: TEAMID.group
        #expect(KeychainSecretStore.validatedAccessGroup("ABCDE12345.app.tildessh.shared") == "ABCDE12345.app.tildessh.shared")
    }

    // MARK: In-memory mock

    @Test func inMemoryStoreContract() throws {
        try exerciseContract(InMemorySecretStore())
    }

    // MARK: Real Keychain (macOS file keychain; skipped where the environment has none)

    @Test func keychainStoreContract() throws {
        #if os(macOS)
        // Unsigned test binaries cannot use the data-protection keychain (no entitlement), and the legacy
        // keychain cannot sync, so this exercises the "this device only" path with a throw-away service name.
        let service = "app.tildessh.secret.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service, accessGroup: nil, useDataProtectionKeychain: false)
        let probe = SecretRef(kind: .password, id: UUID())
        do {
            try store.write(Data("probe".utf8), for: probe, label: "Tilde test", synchronizable: false)
        } catch let error as KeychainError {
            // No usable keychain in this environment (headless CI, locked keychain, sandbox).
            print("Skipping Keychain test: \(error)")
            return
        }
        defer { for ref in (try? store.allRefs()) ?? [] { try? store.delete(ref) } }
        try store.delete(probe)
        try exerciseContract(store)
        #endif
    }

    /// write / read / overwrite / delete / enumerate.
    private func exerciseContract(_ store: any SecretStore) throws {
        let pw = SecretRef(kind: .password, id: UUID())
        let key = SecretRef(kind: .privateKey, id: UUID())
        #expect(try store.read(pw) == nil)
        #expect(try store.allRefs().isEmpty)

        try store.write(Data("one".utf8), for: pw, label: "Tilde: password for deploy@db", synchronizable: false)
        try store.write(Data("-----BEGIN OPENSSH PRIVATE KEY-----".utf8), for: key, label: "Tilde: key", synchronizable: false)
        #expect(try store.read(pw) == Data("one".utf8))
        #expect(Set(try store.allRefs()) == [pw, key])

        // Overwrite replaces, it does not duplicate.
        try store.write(Data("two".utf8), for: pw, label: "Tilde: password for deploy@db", synchronizable: false)
        #expect(try store.read(pw) == Data("two".utf8))
        #expect(try store.allRefs().count == 2)

        try store.delete(pw)
        #expect(try store.read(pw) == nil)
        #expect(try store.read(key) != nil)
        try store.delete(pw)  // deleting a missing secret is not an error
        try store.delete(key)
        #expect(try store.allRefs().isEmpty)
    }

    @Test func inMemoryStoreRecordsLabelAndSyncFlag() throws {
        let store = InMemorySecretStore()
        let ref = SecretRef(kind: .password, id: UUID())
        try store.write(Data("x".utf8), for: ref, label: "Tilde: password for a@b", synchronizable: true)
        #expect(store.entry(for: ref)?.label == "Tilde: password for a@b")
        #expect(store.entry(for: ref)?.synchronizable == true)
    }

    @Test func keychainErrorsDoNotCarrySecrets() {
        let error = KeychainError(status: errSecDuplicateItem)
        #expect(error.status == errSecDuplicateItem)
        #expect(!error.description.isEmpty)
    }
}
