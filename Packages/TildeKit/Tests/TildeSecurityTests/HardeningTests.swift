import Foundation
import Testing
import TildeCore
@testable import TildeSecurity

/// Resource limits, sentinel handling, cancellation and keychain defaults.
@Suite struct HardeningTests {
    let service = DefaultKeyService()

    // MARK: bcrypt rounds

    /// Returns the armored fixture with its bcrypt round count replaced by `rounds`.
    private func fixture(_ name: String, rounds: UInt32) throws -> Data {
        let text = try Fixtures.text(name)
        let body = text.split(separator: "\n").dropFirst().dropLast().joined()
        var container = Array(try #require(Data(base64Encoded: body)))
        var reader = SSHWireReader(Array(container.dropFirst(15)))
        _ = try reader.readString()                       // cipher
        _ = try reader.readString()                       // kdf
        let optionsStart = 15 + reader.offset + 4         // after the options length prefix
        var options = SSHWireReader(Array(container.dropFirst(optionsStart)))
        let salt = try options.readString()
        let roundsOffset = optionsStart + 4 + salt.count
        for (index, byte) in [UInt8(rounds >> 24 & 0xFF), UInt8(rounds >> 16 & 0xFF), UInt8(rounds >> 8 & 0xFF), UInt8(rounds & 0xFF)].enumerated() {
            container[roundsOffset + index] = byte
        }
        return Data(("-----BEGIN OPENSSH PRIVATE KEY-----\n" + Data(container).base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----\n").utf8)
    }

    @Test func oversizedBcryptRoundsAreRejectedBeforeAnyWork() throws {
        for rounds in [OpenSSHPrivateKeyCodec.maxKDFRounds + 1, 100_000, UInt32.max, 0] {
            let data = try fixture("ed25519.enc", rounds: rounds)
            let started = Date()
            do {
                _ = try service.parse(privateKey: data, passphrase: Fixtures.passphrase)
                Issue.record("rounds \(rounds) were accepted")
            } catch KeyParseError.unsupportedFormat {
            } catch {
                Issue.record("rounds \(rounds): unexpected error \(error)")
            }
            #expect(Date().timeIntervalSince(started) < 2)  // rejected up front, no key derivation
        }
    }

    @Test func encodingRejectsUnreasonableRounds() throws {
        let key = try OpenSSHPrivateKeyCodec.decode(Fixtures.data("ed25519"), passphrase: nil)
        #expect(throws: KeyParseError.self) { try OpenSSHPrivateKeyCodec.encode(key, passphrase: "secret", rounds: 5000) }
        #expect(throws: KeyParseError.self) { try OpenSSHPrivateKeyCodec.encode(key, passphrase: "secret", rounds: 0) }
        _ = try OpenSSHPrivateKeyCodec.encode(key, passphrase: "secret", rounds: OpenSSHPrivateKeyCodec.maxKDFRounds > 16 ? 4 : 1)
    }

    // MARK: Cancellation

    @Test func cancelledParseStopsAndThrowsCancellation() async throws {
        let data = try Fixtures.data("ed25519.enc")
        let service = self.service
        let task = Task { try await CancellableKeyParsing.parse(service: service, privateKey: data, passphrase: Fixtures.passphrase) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a cancelled parse completed")
        } catch is CancellationError {
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func uncancelledCancellableParseWorksLikeParse() async throws {
        let (info, _) = try await CancellableKeyParsing.parse(service: service, privateKey: Fixtures.data("ed25519.enc"), passphrase: Fixtures.passphrase)
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("ed25519.fp")))
        do {
            _ = try await CancellableKeyParsing.parse(service: service, privateKey: Fixtures.data("ed25519.enc"), passphrase: "wrong")
            Issue.record("wrong passphrase accepted")
        } catch KeyParseError.wrongPassphrase {
        }
    }

    // MARK: Sentinel

    @Test func sentinelRefsAreRecognised() {
        #expect(DefaultCredentialResolver.unsavedPasswordRef.isUnsavedSentinel)
        #expect(DefaultCredentialResolver.unassignedKeyRef.isUnsavedSentinel)
        #expect(!SecretRef(kind: .password, id: UUID()).isUnsavedSentinel)
        #expect(SecretRef.sentinelID == UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    @Test func keychainRefusesToStoreTheSentinel() throws {
        let store = KeychainSecretStore(service: "app.tildessh.secret.tests.\(UUID().uuidString)", accessGroup: nil, useDataProtectionKeychain: false)
        for kind in [SecretKind.password, .privateKey, .keyPassphrase] {
            do {
                try store.write(Data("x".utf8), for: SecretRef(kind: kind, id: SecretRef.sentinelID), label: "x", synchronizable: false)
                Issue.record("sentinel \(kind) was written")
            } catch let error as KeychainError {
                #expect(error.status == errSecParam)
            }
        }
        #expect(try store.read(SecretRef(kind: .password, id: SecretRef.sentinelID)) == nil)
    }

    // MARK: Keychain defaults

    #if os(macOS)
    /// An unsigned test binary has no keychain entitlement; the default store must still work (file keychain).
    @Test func defaultStoreWorksWithoutEntitlement() throws {
        guard !KeychainSecretStore.dataProtectionKeychainIsAvailable else { return }  // signed: nothing to prove
        let service = "app.tildessh.secret.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service, accessGroup: nil)
        let ref = SecretRef(kind: .password, id: UUID())
        do {
            try store.write(Data("pw".utf8), for: ref, label: "Tilde test", synchronizable: false)
        } catch let error as KeychainError {
            print("Skipping: no usable keychain (\(error))")
            return
        }
        defer { try? store.delete(ref) }
        #expect(try store.read(ref) == Data("pw".utf8))
        // Overwriting (the duplicate-item path) keeps exactly one item.
        try store.write(Data("pw2".utf8), for: ref, label: "Tilde test", synchronizable: false)
        #expect(try store.read(ref) == Data("pw2".utf8))
        #expect(try store.allRefs() == [ref])
    }

    /// A synchronizable item needs the data-protection keychain (a signed app); skipped when unavailable.
    @Test func synchronizableItemRoundTrip() throws {
        let service = "app.tildessh.secret.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service, accessGroup: nil, useDataProtectionKeychain: true)
        let ref = SecretRef(kind: .privateKey, id: UUID())
        do {
            try store.write(Data("key".utf8), for: ref, label: "Tilde test", synchronizable: true)
        } catch let error as KeychainError {
            print("Skipping synchronizable round trip: \(error)")
            return
        }
        defer { try? store.delete(ref) }
        #expect(try store.read(ref) == Data("key".utf8))
        // Flipping the flag moves the item rather than duplicating it.
        try store.write(Data("key2".utf8), for: ref, label: "Tilde test", synchronizable: false)
        #expect(try store.read(ref) == Data("key2".utf8))
        #expect(try store.allRefs() == [ref])
    }
    #endif
}
