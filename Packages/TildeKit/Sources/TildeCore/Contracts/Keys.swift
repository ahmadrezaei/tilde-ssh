import Foundation

// MARK: - Keys (WS3)

/// SSH public-key algorithms Tilde can generate, import and authenticate with.
public enum SSHKeyAlgorithm: String, Codable, Sendable {
    case ed25519 = "ssh-ed25519"
    case ecdsaP256 = "ecdsa-sha2-nistp256"
    case ecdsaP384 = "ecdsa-sha2-nistp384"
    case ecdsaP521 = "ecdsa-sha2-nistp521"
    case rsa = "ssh-rsa"
}

/// Public metadata for a key. Safe to sync and to show in the UI.
public struct PublicKeyInfo: Hashable, Sendable {
    public var algorithm: SSHKeyAlgorithm
    /// RSA modulus size; `nil` for other algorithms.
    public var bits: Int?
    /// The full `ssh-ed25519 AAAA... comment` line.
    public var openSSH: String
    /// `SHA256:` followed by unpadded base64.
    public var fingerprintSHA256: String
    public var comment: String

    public init(algorithm: SSHKeyAlgorithm, bits: Int? = nil, openSSH: String, fingerprintSHA256: String, comment: String) {
        self.algorithm = algorithm
        self.bits = bits
        self.openSSH = openSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.comment = comment
    }
}

/// Unencrypted `openssh-key-v1` private key bytes. Keep lifetimes short and never log.
public struct PrivateKeyMaterial: Sendable {
    public let algorithm: SSHKeyAlgorithm
    /// Unencrypted `openssh-key-v1` serialization.
    public let openSSHBytes: Data

    public init(algorithm: SSHKeyAlgorithm, openSSHBytes: Data) {
        self.algorithm = algorithm
        self.openSSHBytes = openSSHBytes
    }
}

public enum KeyParseError: Error, Sendable {
    case passphraseRequired
    case wrongPassphrase
    case unsupportedFormat(String)
    case unsupportedAlgorithm(String)
}

/// Key generation, parsing and fingerprints.
public protocol KeyService: Sendable {
    func generate(_ algorithm: SSHKeyAlgorithm, bits: Int?, comment: String) async throws -> (PublicKeyInfo, PrivateKeyMaterial)
    func parse(privateKey: Data, passphrase: String?) throws -> (PublicKeyInfo, PrivateKeyMaterial)
    func publicInfo(fromOpenSSHLine: String) throws -> PublicKeyInfo
    /// Returns `"SHA256:base64-no-pad"`.
    func fingerprintSHA256(publicKeyBlob: Data) -> String
}
