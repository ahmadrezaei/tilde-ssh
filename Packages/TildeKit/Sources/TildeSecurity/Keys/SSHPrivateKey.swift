import CryptoKit
import Foundation
import TildeCore

/// The elliptic curves SSH uses for ECDSA keys.
public enum ECDSACurve: Sendable, Hashable {
    case p256, p384, p521

    init?(algorithm: SSHKeyAlgorithm) {
        switch algorithm {
        case .ecdsaP256: self = .p256
        case .ecdsaP384: self = .p384
        case .ecdsaP521: self = .p521
        default: return nil
        }
    }

    public var algorithm: SSHKeyAlgorithm {
        switch self {
        case .p256: .ecdsaP256
        case .p384: .ecdsaP384
        case .p521: .ecdsaP521
        }
    }

    /// The curve identifier inside SSH blobs (`nistp256`...).
    public var sshName: String {
        switch self {
        case .p256: "nistp256"
        case .p384: "nistp384"
        case .p521: "nistp521"
        }
    }

    /// Key size in bits (256 / 384 / 521).
    public var bits: Int {
        switch self {
        case .p256: 256
        case .p384: 384
        case .p521: 521
        }
    }

    /// Length of the private scalar in bytes (32 / 48 / 66).
    public var scalarLength: Int { (bits + 7) / 8 }

    /// Length of an uncompressed public point, `04 || X || Y`.
    var pointLength: Int { 1 + 2 * scalarLength }

    init?(sshName: String) {
        switch sshName {
        case "nistp256": self = .p256
        case "nistp384": self = .p384
        case "nistp521": self = .p521
        default: return nil
        }
    }

    init?(oid: [UInt8]) {
        switch oid {
        case OID.prime256v1: self = .p256
        case OID.secp384r1: self = .p384
        case OID.secp521r1: self = .p521
        default: return nil
        }
    }

    /// Best-effort curve detection when a key does not name its curve with an OID.
    init?(pointLength: Int?, scalarLength: Int) {
        for curve in [ECDSACurve.p256, .p384, .p521] {
            if let pointLength, pointLength == curve.pointLength { self = curve; return }
        }
        for curve in [ECDSACurve.p256, .p384, .p521] where curve.scalarLength == scalarLength {
            self = curve
            return
        }
        return nil
    }
}

/// The CRT parameters of an RSA private key. Every field is an unsigned big-endian magnitude.
public struct RSAPrivateComponents: Sendable {
    public var modulus: Data
    public var publicExponent: Data
    public var privateExponent: Data
    /// `q^-1 mod p`
    public var inverseQ: Data
    public var primeP: Data
    public var primeQ: Data

    public init(modulus: Data, publicExponent: Data, privateExponent: Data, inverseQ: Data, primeP: Data, primeQ: Data) {
        self.modulus = modulus
        self.publicExponent = publicExponent
        self.privateExponent = privateExponent
        self.inverseQ = inverseQ
        self.primeP = primeP
        self.primeQ = primeQ
    }

    /// Modulus size in bits.
    public var bits: Int { bitLength(ofMagnitude: Array(modulus)) }
}

/// A decoded, unencrypted SSH private key. This is the interchange type between the parsers, the
/// `openssh-key-v1` writer and the code that signs with the key. Keep lifetimes short and never log it.
public struct SSHPrivateKey: Sendable {
    public enum Secret: Sendable {
        /// The 32-byte Ed25519 seed.
        case ed25519(seed: Data)
        /// The private scalar (big-endian, fixed length for the curve).
        case ecdsa(curve: ECDSACurve, scalar: Data)
        case rsa(RSAPrivateComponents)
    }

    public var secret: Secret
    /// The free-text comment stored in the key file (may be empty).
    public var comment: String

    public init(secret: Secret, comment: String = "") {
        self.secret = secret
        self.comment = comment
    }

    public var algorithm: SSHKeyAlgorithm {
        switch secret {
        case .ed25519: .ed25519
        case .ecdsa(let curve, _): curve.algorithm
        case .rsa: .rsa
        }
    }

    /// RSA modulus size; `nil` for other algorithms.
    public var bits: Int? {
        if case .rsa(let components) = secret { return components.bits }
        return nil
    }

    /// The SSH public key blob (`string alg || ...`), the thing fingerprints are computed over.
    public func publicKeyBlob() throws -> Data {
        var writer = SSHWireWriter()
        switch secret {
        case .ed25519(let seed):
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            writer.writeString(SSHKeyAlgorithm.ed25519.rawValue)
            writer.writeString(Array(key.publicKey.rawRepresentation))
        case .ecdsa(let curve, let scalar):
            let point = try Self.publicPoint(curve: curve, scalar: scalar)
            writer.writeString(curve.algorithm.rawValue)
            writer.writeString(curve.sshName)
            writer.writeString(point)
        case .rsa(let components):
            writer.writeString(SSHKeyAlgorithm.rsa.rawValue)
            writer.writeMPInt(Array(components.publicExponent))
            writer.writeMPInt(Array(components.modulus))
        }
        return Data(writer.bytes)
    }

    static func publicPoint(curve: ECDSACurve, scalar: Data) throws -> [UInt8] {
        switch curve {
        case .p256: return Array(try P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation)
        case .p384: return Array(try P384.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation)
        case .p521: return Array(try P521.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation)
        }
    }

    /// Public metadata for this key (fingerprint, `authorized_keys` line).
    public func publicInfo() throws -> PublicKeyInfo {
        let blob = try publicKeyBlob()
        return SSHPublicKeyFormat.info(algorithm: algorithm, bits: bits, blob: blob, comment: comment)
    }

    // MARK: Typed key accessors (for the SSH engine)

    /// The key as a CryptoKit Ed25519 key, or `nil` for other algorithms.
    public func ed25519PrivateKey() throws -> Curve25519.Signing.PrivateKey? {
        guard case .ed25519(let seed) = secret else { return nil }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    public func p256PrivateKey() throws -> P256.Signing.PrivateKey? {
        guard case .ecdsa(.p256, let scalar) = secret else { return nil }
        return try P256.Signing.PrivateKey(rawRepresentation: scalar)
    }

    public func p384PrivateKey() throws -> P384.Signing.PrivateKey? {
        guard case .ecdsa(.p384, let scalar) = secret else { return nil }
        return try P384.Signing.PrivateKey(rawRepresentation: scalar)
    }

    public func p521PrivateKey() throws -> P521.Signing.PrivateKey? {
        guard case .ecdsa(.p521, let scalar) = secret else { return nil }
        return try P521.Signing.PrivateKey(rawRepresentation: scalar)
    }
}
