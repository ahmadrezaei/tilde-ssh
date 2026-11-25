import Foundation
import Testing
import TildeCore
@testable import TildeSecurity

/// Parses real `ssh-keygen` / OpenSSL output and checks every result against what `ssh-keygen -lf` printed.
@Suite struct KeyParsingTests {
    let service = DefaultKeyService()

    // MARK: openssh-key-v1, unencrypted

    @Test(arguments: Fixtures.sshKeygenKeys)
    func parsesUnencryptedOpenSSH(fixture: (name: String, algorithm: SSHKeyAlgorithm)) throws {
        let (info, material) = try service.parse(privateKey: Fixtures.data(fixture.name), passphrase: nil)
        #expect(info.algorithm == fixture.algorithm)
        #expect(material.algorithm == fixture.algorithm)
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("\(fixture.name).fp")))
        #expect(info.openSSH.hasPrefix(try Fixtures.publicKeyCore("\(fixture.name).pub")))
        #expect(info.comment == "fixture-\(fixture.name)@tilde")
        if fixture.algorithm == .rsa {
            #expect(info.bits == (fixture.name == "rsa3072" ? 3072 : 4096))
        } else {
            #expect(info.bits == nil)
        }
        // The stored form is itself parseable and stable.
        let (again, _) = try service.parse(privateKey: material.openSSHBytes, passphrase: nil)
        #expect(again == info)
    }

    // MARK: openssh-key-v1, encrypted

    @Test(arguments: Fixtures.sshKeygenKeys)
    func parsesEncryptedOpenSSH(fixture: (name: String, algorithm: SSHKeyAlgorithm)) throws {
        let data = try Fixtures.data("\(fixture.name).enc")
        let (info, _) = try service.parse(privateKey: data, passphrase: Fixtures.passphrase)
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("\(fixture.name).fp")))
        #expect(info.algorithm == fixture.algorithm)
    }

    @Test(arguments: ["ed25519.aes256cbc.enc", "ed25519.aes128ctr.enc"])
    func parsesOtherCiphers(file: String) throws {
        let (info, _) = try service.parse(privateKey: Fixtures.data(file), passphrase: Fixtures.passphrase)
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("ed25519.fp")))
    }

    @Test func encryptedKeyWithoutPassphraseAsksForOne() throws {
        let data = try Fixtures.data("ed25519.enc")
        #expect(throws: KeyParseError.self) { try service.parse(privateKey: data, passphrase: nil) }
        do { _ = try service.parse(privateKey: data, passphrase: nil) } catch KeyParseError.passphraseRequired {} catch { Issue.record("wrong error \(error)") }
        do { _ = try service.parse(privateKey: data, passphrase: "") } catch KeyParseError.passphraseRequired {} catch { Issue.record("wrong error \(error)") }
    }

    @Test func wrongPassphraseIsReported() throws {
        for name in ["ed25519.enc", "ecdsa256.enc", "rsa3072.enc", "ecdsa384.pem.enc", "ecdsa256.p8.enc"] {
            do {
                _ = try service.parse(privateKey: Fixtures.data(name), passphrase: "definitely wrong")
                Issue.record("\(name) accepted a wrong passphrase")
            } catch KeyParseError.wrongPassphrase {
            } catch {
                Issue.record("\(name): expected wrongPassphrase, got \(error)")
            }
        }
    }

    // MARK: PEM / PKCS#8

    @Test(arguments: ["rsa3072", "ecdsa256", "ecdsa384", "ecdsa521"])
    func parsesTraditionalPEM(name: String) throws {
        let pem = try Fixtures.data("\(name).pem")
        let (info, material) = try service.parse(privateKey: pem, passphrase: nil)
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("\(name).fp")))
        #expect(info.comment == "")  // PEM carries no comment
        #expect(material.openSSHBytes.starts(with: Data("-----BEGIN OPENSSH PRIVATE KEY-----".utf8)))
    }

    @Test(arguments: ["rsa3072", "ecdsa256", "ecdsa384", "ecdsa521"])
    func parsesLegacyEncryptedPEM(name: String) throws {
        let (info, _) = try service.parse(privateKey: Fixtures.data("\(name).pem.enc"), passphrase: Fixtures.passphrase)
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("\(name).fp")))
        do { _ = try service.parse(privateKey: Fixtures.data("\(name).pem.enc"), passphrase: nil) } catch KeyParseError.passphraseRequired {} catch { Issue.record("wrong error \(error)") }
    }

    /// LibreSSL's ssh-keygen writes EC PKCS#8 with explicit curve parameters; RSA is plain.
    @Test(arguments: ["rsa3072", "ecdsa256", "ecdsa384", "ecdsa521"])
    func parsesPKCS8FromSSHKeygen(name: String) throws {
        let (info, _) = try service.parse(privateKey: Fixtures.data("\(name).p8"), passphrase: nil)
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("\(name).fp")))
        let (encrypted, _) = try service.parse(privateKey: Fixtures.data("\(name).p8.enc"), passphrase: Fixtures.passphrase)
        #expect(encrypted.fingerprintSHA256 == info.fingerprintSHA256)
    }

    /// Named-curve PKCS#8, SEC1 and PBES2 files made by OpenSSL 3.
    @Test(arguments: [
        "ossl-ed25519.p8", "ossl-ecdsa256.p8", "ossl-ecdsa521.sec1", "ossl-rsa3072.p8",
    ])
    func parsesOpenSSLKeys(file: String) throws {
        let (info, _) = try service.parse(privateKey: Fixtures.data(file), passphrase: nil)
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("\(file).fp")))
    }

    @Test(arguments: ["ossl-ed25519.p8.enc", "ossl-ecdsa384.p8.enc", "ossl-rsa3072.p8.enc"])
    func parsesOpenSSLEncryptedPKCS8(file: String) throws {
        let (info, _) = try service.parse(privateKey: Fixtures.data(file), passphrase: Fixtures.passphrase)
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("\(file).fp")))
    }

    // MARK: Rejections

    @Test func rejectsPuTTYKeys() {
        let ppk = Data("PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n".utf8)
        do { _ = try service.parse(privateKey: ppk, passphrase: nil) } catch KeyParseError.unsupportedFormat(let message) {
            #expect(message.contains("puttygen"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func rejectsDSA() {
        let dsa = Data("-----BEGIN DSA PRIVATE KEY-----\nMIIBuwIBAAKBgQ==\n-----END DSA PRIVATE KEY-----\n".utf8)
        do { _ = try service.parse(privateKey: dsa, passphrase: nil) } catch KeyParseError.unsupportedAlgorithm(let message) {
            #expect(message.contains("DSA"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func rejectsPublicKeysAndGarbage() throws {
        let pub = try Fixtures.data("ed25519.pub")
        for data in [pub, Data("hello world".utf8), Data(), Data([0, 1, 2, 3]), Data("-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----".utf8)] {
            #expect(throws: KeyParseError.self) { try service.parse(privateKey: data, passphrase: nil) }
        }
    }

    @Test func rejectsTruncatedKeys() throws {
        let full = try Fixtures.data("ed25519")
        let text = String(decoding: full, as: UTF8.self)
        let lines = text.split(separator: "\n")
        // Drop the base64 body's second line: still armored, but the container is cut short.
        let cut = ([lines[0]] + lines[2...]).joined(separator: "\n")
        #expect(throws: KeyParseError.self) { try service.parse(privateKey: Data(cut.utf8), passphrase: nil) }
        for length in [0, 5, 40, 120] {
            #expect(throws: (any Error).self) { try OpenSSHPrivateKeyCodec.decode(full.prefix(length), passphrase: nil) }
        }
    }

    /// The decoder must never crash on arbitrary mutations of a valid key. (Passphrase-protected OpenSSH files are
    /// excluded from the heavy loop because every attempt runs bcrypt; a few iterations cover that path.)
    @Test func survivesCorruptedInput() throws {
        var rng = SystemRandomNumberGenerator()
        let cases: [(file: String, passphrase: String?, iterations: Int)] = [
            ("ecdsa256", nil, 300), ("rsa3072", nil, 100), ("ecdsa256.pem", nil, 200), ("rsa3072.p8", nil, 100),
            ("ecdsa384.pem.enc", Fixtures.passphrase, 100), ("ecdsa256.p8.enc", Fixtures.passphrase, 100),
            ("ed25519.enc", Fixtures.passphrase, 3),
        ]
        for testCase in cases {
            let original = Array(try Fixtures.data(testCase.file))
            for _ in 0..<testCase.iterations {
                var bytes = original
                for _ in 0..<3 { bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
                _ = try? service.parse(privateKey: Data(bytes), passphrase: testCase.passphrase)
                _ = try? service.parse(privateKey: Data(bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng))), passphrase: testCase.passphrase)
            }
        }
    }

    // MARK: Public lines

    @Test(arguments: Fixtures.sshKeygenKeys)
    func parsesPublicLines(fixture: (name: String, algorithm: SSHKeyAlgorithm)) throws {
        let line = try Fixtures.text("\(fixture.name).pub")
        let info = try service.publicInfo(fromOpenSSHLine: line)
        #expect(info.algorithm == fixture.algorithm)
        #expect(info.fingerprintSHA256 == (try Fixtures.fingerprint("\(fixture.name).fp")))
        #expect(info.comment == "fixture-\(fixture.name)@tilde")
        #expect(info.openSSH == line.trimmingCharacters(in: .newlines))
    }

    @Test func publicLineWithoutComment() throws {
        let core = try Fixtures.publicKeyCore("ed25519.pub")
        let info = try service.publicInfo(fromOpenSSHLine: core)
        #expect(info.comment == "")
        #expect(info.openSSH == core)
    }

    @Test func publicLineKeepsCommentWithSpaces() throws {
        let line = try Fixtures.publicKeyCore("ed25519.pub") + " my laptop key"
        #expect(try service.publicInfo(fromOpenSSHLine: line).comment == "my laptop key")
    }

    @Test func publicLineRejections() throws {
        let core = try Fixtures.publicKeyCore("ed25519.pub")
        let blob = core.split(separator: " ")[1]
        #expect(throws: KeyParseError.self) { try service.publicInfo(fromOpenSSHLine: "") }
        #expect(throws: KeyParseError.self) { try service.publicInfo(fromOpenSSHLine: "ssh-ed25519") }
        #expect(throws: KeyParseError.self) { try service.publicInfo(fromOpenSSHLine: "ssh-ed25519 !!!notbase64") }
        #expect(throws: KeyParseError.self) { try service.publicInfo(fromOpenSSHLine: "ssh-rsa \(blob)") }  // type mismatch
        #expect(throws: KeyParseError.self) { try service.publicInfo(fromOpenSSHLine: "ssh-ed25519 AAAA") }  // truncated blob
        do { _ = try service.publicInfo(fromOpenSSHLine: "ssh-dss AAAAB3NzaC1kc3M=") } catch KeyParseError.unsupportedAlgorithm(let m) {
            #expect(m.contains("DSA"))
        } catch { Issue.record("wrong error \(error)") }
        do { _ = try service.publicInfo(fromOpenSSHLine: "sk-ssh-ed25519@openssh.com AAAA") } catch KeyParseError.unsupportedAlgorithm {} catch { Issue.record("wrong error \(error)") }
    }
}
