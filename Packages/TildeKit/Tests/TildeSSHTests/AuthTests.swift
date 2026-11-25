import Crypto
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Security
import Testing
import TildeCore
@testable import TildeSSH

/// Splits a `ssh-keygen` public key line into its decoded blob fields.
private func blobFields(_ publicLine: String) -> [Data] {
    let base64 = publicLine.split(separator: " ")[1]
    var reader = SSHWireReader(Data(base64Encoded: String(base64))!)
    var fields: [Data] = []
    while !reader.isAtEnd, let field = reader.readData() { fields.append(field) }
    return fields
}

@Suite struct OpenSSHKeyReaderTests {
    @Test func ed25519SeedMatchesThePublicKey() throws {
        guard case .ed25519(let seed) = try OpenSSHKeyReader.parse(Data(KeyFixtures.ed25519Private.utf8)) else { Issue.record("wrong type"); return }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        #expect(key.publicKey.rawRepresentation == blobFields(KeyFixtures.ed25519Public)[1])
    }

    @Test(arguments: [
        (KeyFixtures.p256Private, KeyFixtures.p256Public, ECDSACurve.p256),
        (KeyFixtures.p384Private, KeyFixtures.p384Public, ECDSACurve.p384),
        (KeyFixtures.p521Private, KeyFixtures.p521Public, ECDSACurve.p521),
    ])
    func ecdsaScalarMatchesThePublicKey(privateText: String, publicLine: String, curve: ECDSACurve) throws {
        guard case .ecdsa(let parsedCurve, let scalar) = try OpenSSHKeyReader.parse(Data(privateText.utf8)) else { Issue.record("wrong type"); return }
        #expect(parsedCurve == curve)
        #expect(scalar.count == curve.scalarLength)
        let q = blobFields(publicLine)[2]
        switch curve {
        case .p256: #expect(try P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation == q)
        case .p384: #expect(try P384.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation == q)
        case .p521: #expect(try P521.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation == q)
        }
    }

    @Test func rsaComponentsMatchThePublicKey() throws {
        guard case .rsa(let c) = try OpenSSHKeyReader.parse(Data(KeyFixtures.rsa2048Private.utf8)) else { Issue.record("wrong type"); return }
        let fields = blobFields(KeyFixtures.rsa2048Public)   // "ssh-rsa", e, n
        #expect(Data(fields[1].drop(while: { $0 == 0 })) == c.publicExponent)
        #expect(Data(fields[2].drop(while: { $0 == 0 })) == c.modulus)
        #expect(c.modulus.count == 256)
    }

    @Test func acceptsRawBinaryAsWellAsPEMArmour() throws {
        let body = KeyFixtures.ed25519Private.split(separator: "\n").dropFirst().dropLast().joined()
        let binary = try #require(Data(base64Encoded: body))
        #expect(throws: Never.self) { try OpenSSHKeyReader.parse(binary) }
    }

    @Test func rejectsEncryptedAndGarbage() {
        #expect(throws: OpenSSHKeyError.encrypted) { try OpenSSHKeyReader.parse(Data(KeyFixtures.encryptedEd25519Private.utf8)) }
        #expect(throws: OpenSSHKeyError.notOpenSSHKey) { try OpenSSHKeyReader.parse(Data("fake-openssh-key".utf8)) }
        #expect(throws: OpenSSHKeyError.self) { try OpenSSHKeyReader.parse(Data()) }
        // Truncated container.
        let truncated = Data(KeyFixtures.ed25519Private.utf8).prefix(120)
        #expect(throws: OpenSSHKeyError.self) { try OpenSSHKeyReader.parse(Data(truncated)) }
    }
}

@Suite struct RSASigningTests {
    private func components() throws -> RSAComponents {
        guard case .rsa(let c) = try OpenSSHKeyReader.parse(Data(KeyFixtures.rsa2048Private.utf8)) else { throw OpenSSHKeyError.notOpenSSHKey }
        return c
    }

    private func verify(_ signature: Data, message: Data, algorithm: SecKeyAlgorithm) throws -> Bool {
        let c = try components()
        let publicKey = try RSASecKeyFactory.makePublicKey(modulus: c.modulus, publicExponent: c.publicExponent)
        var error: Unmanaged<CFError>?
        defer { error?.release() }
        return SecKeyVerifySignature(publicKey, algorithm, message as CFData, signature as CFData, &error)
    }

    @Test func sha512SignatureVerifiesAndIsFullLength() throws {
        let key = try RSAClientPrivateKey<RSASHA512Tag>(components())
        let message = Data("message to sign".utf8)
        let signature = try #require(try key.signature(for: message) as? RSAClientSignature<RSASHA512Tag>)
        #expect(signature.rawRepresentation.count == 256)
        #expect(try verify(signature.rawRepresentation, message: message, algorithm: .rsaSignatureMessagePKCS1v15SHA512))
        #expect(try !verify(signature.rawRepresentation, message: Data("other".utf8), algorithm: .rsaSignatureMessagePKCS1v15SHA512))
        // It must not be a SHA-256 signature in disguise.
        #expect(try !verify(signature.rawRepresentation, message: message, algorithm: .rsaSignatureMessagePKCS1v15SHA256))
    }

    @Test func sha256AndSHA1Variants() throws {
        let message = Data("another message".utf8)
        let s256 = try #require(try RSAClientPrivateKey<RSASHA256Tag>(components()).signature(for: message) as? RSAClientSignature<RSASHA256Tag>)
        #expect(try verify(s256.rawRepresentation, message: message, algorithm: .rsaSignatureMessagePKCS1v15SHA256))
        let s1 = try #require(try RSAClientPrivateKey<RSASHA1Tag>(components()).signature(for: message) as? RSAClientSignature<RSASHA1Tag>)
        #expect(try verify(s1.rawRepresentation, message: message, algorithm: .rsaSignatureMessagePKCS1v15SHA1))
    }

    @Test func wireNamesFollowRFC8332() {
        #expect(RSAClientPublicKey<RSASHA512Tag>.publicKeyPrefix == "rsa-sha2-512")
        #expect(RSAClientPublicKey<RSASHA256Tag>.publicKeyPrefix == "rsa-sha2-256")
        #expect(RSAClientPublicKey<RSASHA1Tag>.publicKeyPrefix == "ssh-rsa")
        #expect(RSAClientSignature<RSASHA512Tag>.signaturePrefix == "rsa-sha2-512")
    }

    @Test func publicKeyAndSignatureWireEncoding() throws {
        let c = try components()
        let key = RSAClientPublicKey<RSASHA512Tag>(publicExponent: c.publicExponent, modulus: c.modulus)
        var buffer = ByteBuffer()
        _ = key.write(to: &buffer)
        let parsed = try RSAClientPublicKey<RSASHA512Tag>.read(from: &buffer)
        #expect(Data(parsed.modulus.drop(while: { $0 == 0 })) == c.modulus)
        #expect(Data(parsed.publicExponent.drop(while: { $0 == 0 })) == c.publicExponent)
        #expect(buffer.readableBytes == 0)
    }

    @Test func derIntegerEncoding() {
        #expect(DER.integer(Data([0])) == Data([0x02, 0x01, 0x00]))
        #expect(DER.integer(Data([0x7F])) == Data([0x02, 0x01, 0x7F]))
        #expect(DER.integer(Data([0x80])) == Data([0x02, 0x02, 0x00, 0x80]))
        #expect(DER.integer(Data([0, 0, 5])) == Data([0x02, 0x01, 0x05]))
        let long = DER.sequence([DER.integer(Data(repeating: 0xFF, count: 200))])
        #expect(Array(long.prefix(4)) == [0x30, 0x81, 0xCC, 0x02])
    }
}

@Suite struct ClientAuthDelegateTests {
    private let loop = MultiThreadedEventLoopGroup.singleton.next()

    private func ask(_ delegate: ClientAuthDelegate, methods: NIOSSHAvailableUserAuthenticationMethods) async throws -> NIOSSHUserAuthenticationOffer? {
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: methods, nextChallengePromise: promise)
        return try await promise.futureResult.get()
    }

    @Test func passwordIsOfferedFirst() async throws {
        let delegate = ClientAuthDelegate(username: "u", credential: .password("pw"))
        let offer = try #require(try await ask(delegate, methods: .all))
        guard case .password(let password) = offer.offer else { Issue.record("not a password offer"); return }
        #expect(password.password == "pw")
        #expect(offer.username == "u")
        #expect(delegate.authenticatedWith == "password")
    }

    @Test func serverWithoutPasswordAuthIsReportedWithItsMethods() async {
        let delegate = ClientAuthDelegate(username: "u", credential: .password("pw"))
        await #expect(throws: AuthRejectedError(method: "password", serverAllows: ["publickey"])) {
            try await ask(delegate, methods: [.publicKey])
        }
    }

    @Test func rejectedPasswordAsksForANewOne() async throws {
        let delegate = ClientAuthDelegate(username: "u", credential: .password("old"), passwordRetry: { "new" })
        _ = try await ask(delegate, methods: .all)
        let second = try #require(try await ask(delegate, methods: [.password]))
        guard case .password(let password) = second.offer else { Issue.record("not a password offer"); return }
        #expect(password.password == "new")
    }

    @Test func cancellingTheRetryPromptGivesUp() async throws {
        let delegate = ClientAuthDelegate(username: "u", credential: .password("old"), passwordRetry: { nil })
        _ = try await ask(delegate, methods: .all)
        await #expect(throws: AuthRejectedError.self) { try await ask(delegate, methods: [.password, .publicKey]) }
    }

    @Test func rsaTriesSHA512ThenSHA256ThenSHA1ThenGivesUp() async throws {
        guard case .rsa = try OpenSSHKeyReader.parse(Data(KeyFixtures.rsa2048Private.utf8)) else { return }
        let credential = try SSHCredential.make(from: .privateKey(PrivateKeyMaterial(algorithm: .rsa, openSSHBytes: Data(KeyFixtures.rsa2048Private.utf8))))
        let delegate = ClientAuthDelegate(username: "u", credential: credential)
        var offered: [String] = []
        for _ in 0..<3 {
            _ = try await ask(delegate, methods: [.publicKey, .password])
            offered.append(delegate.authenticatedWith)
        }
        #expect(offered == ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"])
        await #expect(throws: AuthRejectedError(method: "publickey", serverAllows: ["publickey", "password"])) {
            try await ask(delegate, methods: [.publicKey, .password])
        }
    }

    @Test(arguments: [
        (KeyFixtures.ed25519Private, "ssh-ed25519"),
        (KeyFixtures.p256Private, "ecdsa-sha2-nistp256"),
        (KeyFixtures.p384Private, "ecdsa-sha2-nistp384"),
        (KeyFixtures.p521Private, "ecdsa-sha2-nistp521"),
    ])
    func otherKeyTypesAreASingleAttempt(text: String, algorithm: String) async throws {
        let credential = try SSHCredential.make(from: .privateKey(PrivateKeyMaterial(algorithm: .ed25519, openSSHBytes: Data(text.utf8))))
        let delegate = ClientAuthDelegate(username: "u", credential: credential)
        _ = try await ask(delegate, methods: .all)
        #expect(delegate.authenticatedWith == algorithm)
        await #expect(throws: AuthRejectedError.self) { try await ask(delegate, methods: .all) }
    }

    @Test func keyAuthNeedsPublicKeyToBeAllowed() async throws {
        let credential = try SSHCredential.make(from: .privateKey(PrivateKeyMaterial(algorithm: .ed25519, openSSHBytes: Data(KeyFixtures.ed25519Private.utf8))))
        let delegate = ClientAuthDelegate(username: "u", credential: credential)
        await #expect(throws: AuthRejectedError(method: "publickey", serverAllows: ["password"])) {
            try await ask(delegate, methods: [.password])
        }
    }
}
