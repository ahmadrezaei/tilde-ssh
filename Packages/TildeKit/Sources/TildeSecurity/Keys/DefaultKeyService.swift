import CryptoKit
import Foundation
import Security
import TildeCore

/// Tilde's `KeyService`: generates Ed25519 / ECDSA (CryptoKit) and RSA (`SecKey`) keys, imports OpenSSH, PEM
/// and PKCS#8 keys (including passphrase-protected ones) and computes fingerprints.
///
/// Keys leave this type as `PrivateKeyMaterial` whose `openSSHBytes` are the **unencrypted, armored
/// `openssh-key-v1`** text (UTF-8); see `OpenSSHPrivateKeyCodec`.
public struct DefaultKeyService: KeyService {
    public init() {}

    // MARK: Generate

    public func generate(_ algorithm: SSHKeyAlgorithm, bits: Int?, comment: String) async throws -> (PublicKeyInfo, PrivateKeyMaterial) {
        let secret: SSHPrivateKey.Secret
        switch algorithm {
        case .ed25519:
            secret = .ed25519(seed: Curve25519.Signing.PrivateKey().rawRepresentation)
        case .ecdsaP256:
            secret = .ecdsa(curve: .p256, scalar: P256.Signing.PrivateKey().rawRepresentation)
        case .ecdsaP384:
            secret = .ecdsa(curve: .p384, scalar: P384.Signing.PrivateKey().rawRepresentation)
        case .ecdsaP521:
            secret = .ecdsa(curve: .p521, scalar: P521.Signing.PrivateKey().rawRepresentation)
        case .rsa:
            let size = bits ?? 4096
            guard [2048, 3072, 4096].contains(size) else {
                throw KeyParseError.unsupportedFormat("RSA keys can be 2048, 3072 or 4096 bits.")
            }
            // RSA generation takes up to a second or two; keep it off the caller's executor.
            secret = .rsa(try await Task.detached(priority: .userInitiated) { try RSAKeyGenerator.generate(bits: size) }.value)
        }
        let key = SSHPrivateKey(secret: secret, comment: comment)
        return (try key.publicInfo(), PrivateKeyMaterial(algorithm: algorithm, openSSHBytes: try OpenSSHPrivateKeyCodec.encode(key)))
    }

    // MARK: Parse

    public func parse(privateKey: Data, passphrase: String?) throws -> (PublicKeyInfo, PrivateKeyMaterial) {
        let key = try Self.decode(privateKey, passphrase: passphrase)
        return (try key.publicInfo(), PrivateKeyMaterial(algorithm: key.algorithm, openSSHBytes: try OpenSSHPrivateKeyCodec.encode(key)))
    }

    /// Decodes any supported private key encoding into an `SSHPrivateKey`.
    static func decode(_ data: Data, passphrase: String?) throws -> SSHPrivateKey {
        if OpenSSHPrivateKeyCodec.looksLikeOpenSSHKey(data) {
            return try OpenSSHPrivateKeyCodec.decode(data, passphrase: passphrase)
        }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{FEFF}"))),
              !text.isEmpty else {
            throw KeyParseError.unsupportedFormat("Not a recognised private key file.")
        }
        if text.hasPrefix("PuTTY-User-Key-File-") {
            throw KeyParseError.unsupportedFormat("PuTTY .ppk keys are not supported. Convert with: puttygen key.ppk -O private-openssh")
        }
        if text.contains("BEGIN DSA PRIVATE KEY") {
            throw KeyParseError.unsupportedAlgorithm("DSA is insecure and disabled in OpenSSH.")
        }
        if text.contains("BEGIN SSH2 ENCRYPTED PRIVATE KEY") {
            throw KeyParseError.unsupportedFormat("ssh.com keys are not supported. Convert with: ssh-keygen -i -f key")
        }
        if let block = PEMKeyDecoder.firstBlock(in: text) {
            if block.label.hasSuffix("PUBLIC KEY") {
                throw KeyParseError.unsupportedFormat("That is a public key. Import the private key file instead.")
            }
            return try PEMKeyDecoder.decode(block, passphrase: passphrase)
        }
        if text.hasPrefix("ssh-") || text.hasPrefix("ecdsa-") || text.hasPrefix("sk-") {
            throw KeyParseError.unsupportedFormat("That is a public key (.pub). Import the private key file instead.")
        }
        throw KeyParseError.unsupportedFormat("Not a recognised private key file.")
    }

    // MARK: Public info & fingerprints

    public func publicInfo(fromOpenSSHLine line: String) throws -> PublicKeyInfo {
        try SSHPublicKeyFormat.parseLine(line)
    }

    public func fingerprintSHA256(publicKeyBlob: Data) -> String {
        KeyFingerprint.sha256(publicKeyBlob: publicKeyBlob)
    }
}

extension PublicKeyInfo {
    /// The same key with a different comment (the `openSSH` line is rebuilt).
    public func replacingComment(_ comment: String) -> PublicKeyInfo {
        let parts = openSSH.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " })
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return self }
        return SSHPublicKeyFormat.info(algorithm: algorithm, bits: bits, blob: blob, comment: comment)
    }
}

/// RSA key generation with `SecKey` (CryptoKit has no RSA key generation).
enum RSAKeyGenerator {
    static func generate(bits: Int) throws -> RSAPrivateComponents {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: bits,
            kSecAttrIsPermanent: false,
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw KeyParseError.unsupportedFormat("RSA key generation failed.")
        }
        guard let external = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw KeyParseError.unsupportedFormat("RSA key export failed.")
        }
        var der = Array(external)
        defer { wipe(&der) }
        guard let key = try? PEMKeyDecoder.pkcs1(der), case .rsa(let components) = key.secret else {
            throw KeyParseError.unsupportedFormat("RSA key export produced an unexpected encoding.")
        }
        return components
    }
}
