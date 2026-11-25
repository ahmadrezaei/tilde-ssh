import BigInt
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security

// RSA client authentication with SHA-2 signatures (RFC 8332).
//
// Citadel's RSA key type signs with SHA-1 (`ssh-rsa`), which OpenSSH 8.8 and later reject by default.
// These types plug into NIOSSH's custom-key hooks instead and sign with `rsa-sha2-512` / `rsa-sha2-256`
// (and `ssh-rsa` as a last resort for very old servers), using the system `SecKey` implementation.
//
// Wire note: NIOSSH writes the key blob header and the "public key algorithm name" field from the same
// string (`publicKeyPrefix`). RFC 8332 wants the algorithm name `rsa-sha2-512` but the blob header
// `ssh-rsa`. We can only supply one string, so the blob header carries the algorithm name. OpenSSH's
// `sshkey_from_blob` resolves both names to an RSA key and the authorised-key comparison uses the key
// material only, so this interoperates (verified against OpenSSH 9.x in the integration tests).

/// How an RSA signature is produced and named on the wire.
enum RSASignatureScheme: Sendable, CaseIterable {
    case sha512, sha256, sha1

    /// Name used for both the signature and the public key algorithm field.
    var name: String {
        switch self {
        case .sha512: "rsa-sha2-512"
        case .sha256: "rsa-sha2-256"
        case .sha1: "ssh-rsa"
        }
    }

    var secKeyAlgorithm: SecKeyAlgorithm {
        switch self {
        case .sha512: .rsaSignatureMessagePKCS1v15SHA512
        case .sha256: .rsaSignatureMessagePKCS1v15SHA256
        case .sha1: .rsaSignatureMessagePKCS1v15SHA1
        }
    }
}

/// Type-level tag so each scheme gets its own static `publicKeyPrefix` / `signaturePrefix`.
protocol RSASchemeTag: Sendable {
    static var scheme: RSASignatureScheme { get }
}
enum RSASHA512Tag: RSASchemeTag { static let scheme = RSASignatureScheme.sha512 }
enum RSASHA256Tag: RSASchemeTag { static let scheme = RSASignatureScheme.sha256 }
enum RSASHA1Tag: RSASchemeTag { static let scheme = RSASignatureScheme.sha1 }

enum RSAKeyError: Error {
    case invalidKey
    case signingFailed
}

// MARK: - NIOSSH key types

struct RSAClientPublicKey<Tag: RSASchemeTag>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Tag.scheme.name }

    let publicExponent: Data
    let modulus: Data

    var rawRepresentation: Data {
        var buffer = ByteBuffer()
        _ = write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeMPInt(publicExponent) + buffer.writeMPInt(modulus)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSAClientPublicKey<Tag> {
        guard let e = buffer.readSSHBytes(), let n = buffer.readSSHBytes() else { throw RSAKeyError.invalidKey }
        return RSAClientPublicKey(publicExponent: e, modulus: n)
    }

    /// Tilde only ever signs; verification is the server's job.
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool { false }
}

struct RSAClientSignature<Tag: RSASchemeTag>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Tag.scheme.name }

    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHBytes(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> RSAClientSignature<Tag> {
        guard let raw = buffer.readSSHBytes() else { throw RSAKeyError.invalidKey }
        return RSAClientSignature(rawRepresentation: raw)
    }
}

/// An RSA private key that signs with the scheme named by `Tag`.
///
/// `@unchecked Sendable`: `SecKey` is an immutable, thread-safe Core Foundation object, and the other
/// stored properties are immutable `Data`.
final class RSAClientPrivateKey<Tag: RSASchemeTag>: NIOSSHPrivateKeyProtocol, @unchecked Sendable {
    static var keyPrefix: String { Tag.scheme.name }

    private let secKey: SecKey
    private let publicExponent: Data
    private let modulus: Data

    init(_ components: RSAComponents) throws {
        self.secKey = try RSASecKeyFactory.makePrivateKey(components)
        self.publicExponent = components.publicExponent
        self.modulus = components.modulus
    }

    var publicKey: NIOSSHPublicKeyProtocol {
        RSAClientPublicKey<Tag>(publicExponent: publicExponent, modulus: modulus)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(secKey, Tag.scheme.secKeyAlgorithm, Data(data) as CFData, &error) as Data? else {
            error?.release()
            throw RSAKeyError.signingFailed
        }
        return RSAClientSignature<Tag>(rawRepresentation: signature)
    }
}

extension RSAClientPrivateKey {
    /// Wraps this key for NIOSSH.
    var nioKey: NIOSSHPrivateKey { NIOSSHPrivateKey(custom: self) }
}

// MARK: - SecKey construction

enum RSASecKeyFactory {
    /// Builds a private `SecKey` from the components of an `openssh-key-v1` RSA key. The OpenSSH container
    /// omits the CRT exponents, so `dp = d mod (p-1)` and `dq = d mod (q-1)` are derived here.
    static func makePrivateKey(_ c: RSAComponents) throws -> SecKey {
        let one = BigUInt(1)
        let d = BigUInt(c.privateExponent)
        let p = BigUInt(c.primeP)
        let q = BigUInt(c.primeQ)
        guard p > one, q > one else { throw RSAKeyError.invalidKey }
        let dp = d % (p - one)
        let dq = d % (q - one)

        let der = DER.sequence([
            DER.integer(Data([0])),
            DER.integer(c.modulus),
            DER.integer(c.publicExponent),
            DER.integer(c.privateExponent),
            DER.integer(c.primeP),
            DER.integer(c.primeQ),
            DER.integer(dp.serialize()),
            DER.integer(dq.serialize()),
            DER.integer(c.inverseQ),
        ])
        return try makeKey(der: der, isPrivate: true)
    }

    /// Public half, used by tests to verify signatures.
    static func makePublicKey(modulus: Data, publicExponent: Data) throws -> SecKey {
        try makeKey(der: DER.sequence([DER.integer(modulus), DER.integer(publicExponent)]), isPrivate: false)
    }

    private static func makeKey(der: Data, isPrivate: Bool) throws -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            error?.release()
            throw RSAKeyError.invalidKey
        }
        return key
    }
}

/// The few ASN.1 DER encodings PKCS#1 needs.
enum DER {
    static func integer(_ magnitude: Data) -> Data {
        var bytes = Array(magnitude.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(tag: 0x02, Data(bytes))
    }

    static func sequence(_ elements: [Data]) -> Data {
        tlv(tag: 0x30, elements.reduce(Data(), +))
    }

    private static func tlv(tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let length = content.count
        if length < 0x80 {
            out.append(UInt8(length))
        } else {
            var lengthBytes: [UInt8] = []
            var remaining = length
            while remaining > 0 {
                lengthBytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            out.append(0x80 | UInt8(lengthBytes.count))
            out.append(contentsOf: lengthBytes)
        }
        out.append(content)
        return out
    }
}

// MARK: - ByteBuffer helpers

extension ByteBuffer {
    /// Writes an SSH `mpint` (unsigned magnitude).
    @discardableResult
    mutating func writeMPInt(_ magnitude: Data) -> Int {
        let trimmed = magnitude.drop(while: { $0 == 0 })
        let needsZero = (trimmed.first ?? 0) & 0x80 != 0
        var written = writeInteger(UInt32(trimmed.count + (needsZero ? 1 : 0)))
        if needsZero { written += writeInteger(UInt8(0)) }
        written += writeBytes(trimmed)
        return written
    }

    /// Writes an SSH `string`.
    @discardableResult
    mutating func writeSSHBytes(_ bytes: Data) -> Int {
        writeInteger(UInt32(bytes.count)) + writeBytes(bytes)
    }

    /// Reads an SSH `string` / `mpint` as raw bytes (leading zeros kept).
    mutating func readSSHBytes() -> Data? {
        guard let length = readInteger(as: UInt32.self), let bytes = readBytes(length: Int(length)) else { return nil }
        return Data(bytes)
    }
}
