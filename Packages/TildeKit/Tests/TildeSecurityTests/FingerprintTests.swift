import Foundation
import Testing
import TildeCore
@testable import TildeSecurity

@Suite struct FingerprintTests {
    let service = DefaultKeyService()

    @Test(arguments: Fixtures.sshKeygenKeys)
    func fingerprintMatchesSSHKeygen(fixture: (name: String, algorithm: SSHKeyAlgorithm)) throws {
        let line = try Fixtures.publicKeyCore("\(fixture.name).pub")
        let blob = try #require(Data(base64Encoded: String(line.split(separator: " ")[1])))
        #expect(service.fingerprintSHA256(publicKeyBlob: blob) == (try Fixtures.fingerprint("\(fixture.name).fp")))
    }

    @Test func fingerprintFormat() {
        let fp = service.fingerprintSHA256(publicKeyBlob: Data([1, 2, 3]))
        #expect(fp.hasPrefix("SHA256:"))
        #expect(fp.count == 7 + 43)  // 32 bytes -> 43 base64 chars without padding
        #expect(!fp.contains("="))
        // Known vector: SHA-256("") = 47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
        #expect(service.fingerprintSHA256(publicKeyBlob: Data()) == "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU")
    }

    @Test(arguments: Fixtures.sshKeygenKeys)
    func randomartMatchesSSHKeygen(fixture: (name: String, algorithm: SSHKeyAlgorithm)) throws {
        let info = try service.publicInfo(fromOpenSSHLine: Fixtures.text("\(fixture.name).pub"))
        let art = try #require(RandomArt.render(fingerprintSHA256: info.fingerprintSHA256, algorithm: info.algorithm, bits: info.bits))
        #expect(art == (try Fixtures.randomart("\(fixture.name).art")))
    }

    @Test func randomartShape() throws {
        let art = try #require(RandomArt.render(fingerprintSHA256: "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU", algorithm: .ed25519, bits: nil))
        let lines = art.split(separator: "\n")
        #expect(lines.count == 11)
        #expect(lines.allSatisfy { $0.count == 19 })
        #expect(lines.first == "+--[ED25519 256]--+")
        #expect(lines.last == "+----[SHA256]-----+")
        #expect(RandomArt.render(fingerprintSHA256: "garbage", algorithm: .ed25519, bits: nil) == nil)
    }

    @Test func digestRoundTrip() throws {
        let fp = service.fingerprintSHA256(publicKeyBlob: Data("abc".utf8))
        let digest = try #require(KeyFingerprint.digest(fromFingerprint: fp))
        #expect(digest.count == 32)
        #expect(KeyFingerprint.digest(fromFingerprint: "MD5:aa") == nil)
        #expect(KeyFingerprint.abbreviated(fp).hasPrefix("SHA256:"))
        #expect(KeyFingerprint.abbreviated(fp).contains("…"))
    }
}
