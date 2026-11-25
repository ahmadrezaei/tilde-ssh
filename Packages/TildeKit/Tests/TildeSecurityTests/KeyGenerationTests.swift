import Citadel
import CryptoKit
import Foundation
import Testing
import TildeCore
@testable import TildeSecurity

/// Generation, serialization and the cross-checks against the real `ssh-keygen`.
@Suite struct KeyGenerationTests {
    let service = DefaultKeyService()

    static let generated: [(algorithm: SSHKeyAlgorithm, bits: Int?)] = [
        (.ed25519, nil), (.ecdsaP256, nil), (.ecdsaP384, nil), (.ecdsaP521, nil), (.rsa, 2048), (.rsa, 3072),
    ]

    @Test(arguments: generated)
    func generatedKeysRoundTrip(spec: (algorithm: SSHKeyAlgorithm, bits: Int?)) async throws {
        let (info, material) = try await service.generate(spec.algorithm, bits: spec.bits, comment: "tilde@test")
        #expect(info.algorithm == spec.algorithm)
        #expect(material.algorithm == spec.algorithm)
        #expect(info.comment == "tilde@test")
        #expect(info.openSSH.hasPrefix(spec.algorithm.rawValue + " "))
        #expect(info.openSSH.hasSuffix(" tilde@test"))
        if spec.algorithm == .rsa { #expect(info.bits == spec.bits) } else { #expect(info.bits == nil) }
        #expect(info.fingerprintSHA256.hasPrefix("SHA256:"))
        #expect(!info.fingerprintSHA256.contains("="))

        let text = String(decoding: material.openSSHBytes, as: UTF8.self)
        #expect(text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n"))
        #expect(text.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        #expect(text.split(separator: "\n").dropFirst().dropLast().allSatisfy { $0.count <= 70 })

        let (parsed, again) = try service.parse(privateKey: material.openSSHBytes, passphrase: nil)
        #expect(parsed == info)
        #expect(again.algorithm == spec.algorithm)
        // The public line re-parses to the same info.
        #expect(try service.publicInfo(fromOpenSSHLine: info.openSSH) == info)
    }

    @Test func generatedKeysAreUnique() async throws {
        let (a, _) = try await service.generate(.ed25519, bits: nil, comment: "")
        let (b, _) = try await service.generate(.ed25519, bits: nil, comment: "")
        #expect(a.fingerprintSHA256 != b.fingerprintSHA256)
    }

    @Test func rsaDefaultsTo4096AndRejectsOddSizes() async throws {
        await #expect(throws: KeyParseError.self) { try await service.generate(.rsa, bits: 1024, comment: "") }
    }

    @Test func passphraseExportRoundTrips() async throws {
        for algorithm in [SSHKeyAlgorithm.ed25519, .ecdsaP256, .ecdsaP521] {
            let (info, material) = try await service.generate(algorithm, bits: nil, comment: "export")
            let encrypted = try OpenSSHPrivateKeyCodec.export(openSSHBytes: material.openSSHBytes, passphrase: "s3cret pass")
            #expect(String(decoding: encrypted, as: UTF8.self).hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
            #expect(encrypted != material.openSSHBytes)
            do { _ = try service.parse(privateKey: encrypted, passphrase: nil) } catch KeyParseError.passphraseRequired {} catch { Issue.record("\(error)") }
            do { _ = try service.parse(privateKey: encrypted, passphrase: "nope") } catch KeyParseError.wrongPassphrase {} catch { Issue.record("\(error)") }
            let (restored, restoredMaterial) = try service.parse(privateKey: encrypted, passphrase: "s3cret pass")
            #expect(restored == info)
            #expect(restoredMaterial.algorithm == algorithm)
        }
    }

    @Test func exportWithoutPassphraseIsUnencrypted() async throws {
        let (info, material) = try await service.generate(.ed25519, bits: nil, comment: "x")
        let plain = try OpenSSHPrivateKeyCodec.export(openSSHBytes: material.openSSHBytes, passphrase: nil)
        #expect(try service.parse(privateKey: plain, passphrase: nil).0 == info)
        #expect(try service.parse(privateKey: plain, passphrase: "ignored when unencrypted").0 == info)
    }

    /// Re-encoding an imported key must not change what key it is.
    @Test(arguments: Fixtures.sshKeygenKeys)
    func importPreservesIdentity(fixture: (name: String, algorithm: SSHKeyAlgorithm)) throws {
        let (info, material) = try service.parse(privateKey: Fixtures.data(fixture.name), passphrase: nil)
        let (info2, _) = try service.parse(privateKey: material.openSSHBytes, passphrase: nil)
        #expect(info2 == info)
    }

    @Test func replacingCommentRebuildsLine() throws {
        let info = try service.publicInfo(fromOpenSSHLine: Fixtures.text("ed25519.pub"))
        let renamed = info.replacingComment("new comment")
        #expect(renamed.comment == "new comment")
        #expect(renamed.openSSH.hasSuffix(" new comment"))
        #expect(renamed.fingerprintSHA256 == info.fingerprintSHA256)
        #expect(info.replacingComment("").openSSH == (try Fixtures.publicKeyCore("ed25519.pub")))
    }

    // MARK: Typed keys (for the SSH engine)

    @Test func typedAccessorsMatchPublicKeys() throws {
        let ed = try OpenSSHPrivateKeyCodec.decode(Fixtures.data("ed25519"), passphrase: nil)
        let edBlob = try ed.publicKeyBlob()
        #expect(try ed.ed25519PrivateKey()?.publicKey.rawRepresentation == edBlob.suffix(32))
        #expect(try ed.p256PrivateKey() == nil)

        let ec = try OpenSSHPrivateKeyCodec.decode(Fixtures.data("ecdsa384"), passphrase: nil)
        let key = try #require(try ec.p384PrivateKey())
        #expect(key.publicKey.x963Representation == (try ec.publicKeyBlob()).suffix(97))
        // Signing with the extracted key verifies against the public half.
        let message = Data("hello".utf8)
        #expect(key.publicKey.isValidSignature(try key.signature(for: message), for: message))
    }

    // MARK: Cross-checks against ssh-keygen

    @Test(arguments: Fixtures.sshKeygenKeys)
    func sshKeygenAcceptsOurSerialization(fixture: (name: String, algorithm: SSHKeyAlgorithm)) throws {
        guard SSHKeygen.isAvailable else { return }
        let (info, material) = try service.parse(privateKey: Fixtures.data(fixture.name), passphrase: nil)
        let derived = try SSHKeygen.withTempKeyFile(material.openSSHBytes) { path in SSHKeygen.run(["-y", "-f", path]) }
        let line = try #require(derived)
        #expect(line.split(separator: " ").prefix(2).joined(separator: " ") == (try Fixtures.publicKeyCore("\(fixture.name).pub")))
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("\(fixture.name).fp")))
    }

    @Test(arguments: generated)
    func sshKeygenAcceptsGeneratedKeys(spec: (algorithm: SSHKeyAlgorithm, bits: Int?)) async throws {
        guard SSHKeygen.isAvailable else { return }
        let (info, material) = try await service.generate(spec.algorithm, bits: spec.bits, comment: "xcheck")
        // Private key -> public key, and the fingerprint ssh-keygen computes for our public line.
        let derived = try #require(try SSHKeygen.withTempKeyFile(material.openSSHBytes) { SSHKeygen.run(["-y", "-f", $0]) })
        #expect(derived.split(separator: " ").prefix(2).joined(separator: " ") == info.openSSH.split(separator: " ").prefix(2).joined(separator: " "))
        let listing = try #require(try SSHKeygen.withTempKeyFile(Data(info.openSSH.utf8)) { SSHKeygen.run(["-l", "-f", $0]) })
        #expect(listing.split(separator: " ")[1] == info.fingerprintSHA256)
    }

    @Test func sshKeygenDecryptsOurEncryptedExport() async throws {
        guard SSHKeygen.isAvailable else { return }
        for algorithm in [SSHKeyAlgorithm.ed25519, .ecdsaP256, .rsa] {
            let (info, material) = try await service.generate(algorithm, bits: algorithm == .rsa ? 2048 : nil, comment: "enc")
            let encrypted = try OpenSSHPrivateKeyCodec.export(openSSHBytes: material.openSSHBytes, passphrase: "export-pass")
            let derived = try #require(try SSHKeygen.withTempKeyFile(encrypted) { SSHKeygen.run(["-y", "-P", "export-pass", "-f", $0]) })
            #expect(derived.split(separator: " ").prefix(2).joined(separator: " ") == info.openSSH.split(separator: " ").prefix(2).joined(separator: " "))
        }
    }

    // MARK: Citadel interop (what the SSH engine is fed)

    @Test func citadelAcceptsOurEd25519AndRSABytes() async throws {
        let (edInfo, edMaterial) = try await service.generate(.ed25519, bits: nil, comment: "interop")
        let edKey = try Curve25519.Signing.PrivateKey(sshEd25519: edMaterial.openSSHBytes)
        let edBlob = try #require(Data(base64Encoded: String(edInfo.openSSH.split(separator: " ")[1])))
        #expect(edBlob.suffix(32) == edKey.publicKey.rawRepresentation)

        let (_, rsaMaterial) = try await service.generate(.rsa, bits: 2048, comment: "interop")
        _ = try Insecure.RSA.PrivateKey(sshRsa: rsaMaterial.openSSHBytes)
    }

    @Test func citadelAcceptsImportedKeysAfterReencoding() throws {
        let (_, edMaterial) = try service.parse(privateKey: Fixtures.data("ed25519.enc"), passphrase: Fixtures.passphrase)
        _ = try Curve25519.Signing.PrivateKey(sshEd25519: edMaterial.openSSHBytes)
        let (_, rsaMaterial) = try service.parse(privateKey: Fixtures.data("rsa3072.pem"), passphrase: nil)
        _ = try Insecure.RSA.PrivateKey(sshRsa: rsaMaterial.openSSHBytes)
    }
}
