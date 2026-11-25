import Foundation
import Testing
import TildeCore
@testable import TildeSecurity

@Suite struct CredentialResolverTests {
    let target = ConnectionTarget(host: "10.0.1.12", username: "deploy")

    private func makeResolver() -> (DefaultCredentialResolver, InMemorySecretStore) {
        let store = InMemorySecretStore()
        return (DefaultCredentialResolver(secretStore: store), store)
    }

    @Test func resolvesStoredPassword() async throws {
        let (resolver, store) = makeResolver()
        let id = UUID()
        try store.write(Data("hunter2".utf8), for: SecretRef(kind: .password, id: id), label: "x", synchronizable: true)
        let credential = try await resolver.resolve(auth: .password, keyID: nil, passwordSecretID: id, target: target)
        guard case .password(let password) = credential else { Issue.record("expected password"); return }
        #expect(password == "hunter2")
    }

    @Test func missingPasswordSecretIsUnavailable() async throws {
        let (resolver, _) = makeResolver()
        let id = UUID()
        await expectUnavailable(SecretRef(kind: .password, id: id)) {
            _ = try await resolver.resolve(auth: .password, keyID: nil, passwordSecretID: id, target: target)
        }
    }

    @Test func unsavedAndPromptPasswordsUseTheSentinel() async throws {
        let (resolver, _) = makeResolver()
        await expectUnavailable(DefaultCredentialResolver.unsavedPasswordRef) {
            _ = try await resolver.resolve(auth: .password, keyID: nil, passwordSecretID: nil, target: target)
        }
        await expectUnavailable(DefaultCredentialResolver.unsavedPasswordRef) {
            _ = try await resolver.resolve(auth: .passwordPrompt, keyID: nil, passwordSecretID: UUID(), target: target)
        }
    }

    @Test func resolvesStoredKey() async throws {
        let (resolver, store) = makeResolver()
        let (info, material) = try await DefaultKeyService().generate(.ed25519, bits: nil, comment: "t")
        let id = UUID()
        try store.write(material.openSSHBytes, for: SecretRef(kind: .privateKey, id: id), label: "k", synchronizable: true)
        let credential = try await resolver.resolve(auth: .key, keyID: id, passwordSecretID: nil, target: target)
        guard case .privateKey(let resolved) = credential else { Issue.record("expected key"); return }
        #expect(resolved.algorithm == .ed25519)
        #expect(resolved.openSSHBytes == material.openSSHBytes)
        #expect(try DefaultKeyService().parse(privateKey: resolved.openSSHBytes, passphrase: nil).0 == info)
    }

    @Test func missingKeyIsUnavailable() async throws {
        let (resolver, _) = makeResolver()
        let id = UUID()
        await expectUnavailable(SecretRef(kind: .privateKey, id: id)) {
            _ = try await resolver.resolve(auth: .key, keyID: id, passwordSecretID: nil, target: target)
        }
        await expectUnavailable(DefaultCredentialResolver.unassignedKeyRef) {
            _ = try await resolver.resolve(auth: .key, keyID: nil, passwordSecretID: nil, target: target)
        }
    }

    @Test func passphraseProtectedStoredKeyUsesKeyPassphraseSecret() async throws {
        let (resolver, store) = makeResolver()
        let (info, material) = try await DefaultKeyService().generate(.ecdsaP256, bits: nil, comment: "t")
        let encrypted = try OpenSSHPrivateKeyCodec.export(openSSHBytes: material.openSSHBytes, passphrase: "pw", rounds: 4)
        let id = UUID()
        try store.write(encrypted, for: SecretRef(kind: .privateKey, id: id), label: "k", synchronizable: false)

        // Without the passphrase secret: waiting for it.
        await expectUnavailable(SecretRef(kind: .keyPassphrase, id: id)) {
            _ = try await resolver.resolve(auth: .key, keyID: id, passwordSecretID: nil, target: target)
        }
        try store.write(Data("pw".utf8), for: SecretRef(kind: .keyPassphrase, id: id), label: "p", synchronizable: false)
        let credential = try await resolver.resolve(auth: .key, keyID: id, passwordSecretID: nil, target: target)
        guard case .privateKey(let resolved) = credential else { Issue.record("expected key"); return }
        // The engine receives the unencrypted form.
        #expect(try DefaultKeyService().parse(privateKey: resolved.openSSHBytes, passphrase: nil).0 == info)
    }

    @Test func corruptStoredKeyIsAnErrorWithoutLeakingBytes() async throws {
        let (resolver, store) = makeResolver()
        let id = UUID()
        try store.write(Data("SUPER-SECRET-NOT-A-KEY".utf8), for: SecretRef(kind: .privateKey, id: id), label: "k", synchronizable: true)
        do {
            _ = try await resolver.resolve(auth: .key, keyID: id, passwordSecretID: nil, target: target)
            Issue.record("expected an error")
        } catch let error as SessionError {
            #expect(!String(describing: error).contains("SUPER-SECRET"))
        }
    }

    private func expectUnavailable(_ expected: SecretRef, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected secretUnavailable")
        } catch SessionError.secretUnavailable(let ref) {
            #expect(ref == expected)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
