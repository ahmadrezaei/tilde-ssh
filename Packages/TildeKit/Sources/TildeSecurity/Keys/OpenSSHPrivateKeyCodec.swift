import Foundation
import Security
import TildeCore

/// Reads and writes the `openssh-key-v1` private key container (PROTOCOL.key in the OpenSSH sources),
/// armored as `-----BEGIN OPENSSH PRIVATE KEY-----`.
///
/// Tilde stores private keys in the Keychain as the **unencrypted, armored** form produced by `encode`
/// (UTF-8 text, newline terminated). Citadel's `Curve25519.Signing.PrivateKey(sshEd25519:)` and
/// `Insecure.RSA.PrivateKey(sshRsa:)` accept exactly these bytes.
public enum OpenSSHPrivateKeyCodec {
    static let header = "-----BEGIN OPENSSH PRIVATE KEY-----"
    static let footer = "-----END OPENSSH PRIVATE KEY-----"
    private static let magic = Array("openssh-key-v1".utf8) + [0]
    /// ssh-keygen's default is 16 bcrypt rounds.
    public static let defaultKDFRounds: UInt32 = 16
    /// Keys asking for more bcrypt rounds are rejected: it would freeze the UI for a long time (a hostile file could
    /// otherwise ask for billions).
    public static let maxKDFRounds: UInt32 = 1024

    // MARK: Decoding

    /// Decodes an `openssh-key-v1` key (armored text or the raw binary container).
    /// - Parameter passphrase: required when the key is encrypted.
    /// - Throws: `KeyParseError` (`passphraseRequired`, `wrongPassphrase`, `unsupportedFormat`, `unsupportedAlgorithm`).
    public static func decode(_ data: Data, passphrase: String?) throws -> SSHPrivateKey {
        let container = try unarmor(data)
        do {
            return try decodeContainer(container, passphrase: passphrase)
        } catch let error as KeyParseError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch KeyCipherError.cancelled {
            throw CancellationError()
        } catch let error as KeyCipherError {
            _ = error
            throw KeyParseError.unsupportedFormat("The key could not be decrypted.")
        } catch {
            throw KeyParseError.unsupportedFormat("The key file is truncated or corrupt.")
        }
    }

    /// `true` when `data` looks like an `openssh-key-v1` file.
    public static func looksLikeOpenSSHKey(_ data: Data) -> Bool {
        if data.starts(with: magic) { return true }
        guard let text = String(data: data.prefix(4096), encoding: .utf8) else { return false }
        return text.contains(header)
    }

    private static func unarmor(_ data: Data) throws -> [UInt8] {
        if data.starts(with: magic) { return Array(data) }
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: header), let end = text.range(of: footer), start.upperBound <= end.lowerBound
        else { throw KeyParseError.unsupportedFormat("Not an OpenSSH private key.") }
        let body = text[start.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let decoded = Data(base64Encoded: String(body)) else {
            throw KeyParseError.unsupportedFormat("The key body is not valid base64.")
        }
        return Array(decoded)
    }

    private static func decodeContainer(_ container: [UInt8], passphrase: String?) throws -> SSHPrivateKey {
        guard container.starts(with: magic) else { throw KeyParseError.unsupportedFormat("Missing openssh-key-v1 magic.") }
        var reader = SSHWireReader(Array(container.dropFirst(magic.count)))
        let cipherName = try reader.readUTF8String()
        let kdfName = try reader.readUTF8String()
        let kdfOptions = try reader.readString()
        let keyCount = try reader.readUInt32()
        guard keyCount == 1 else { throw KeyParseError.unsupportedFormat("Files with several keys are not supported.") }
        let publicBlob = try reader.readString()
        var section = try reader.readString()
        defer { wipe(&section) }

        // Refuse algorithms we do not support before asking for a passphrase.
        _ = try SSHPublicKeyFormat.parseBlob(publicBlob)

        let isEncrypted = cipherName != "none"
        if isEncrypted {
            guard let cipher = OpenSSHCipher(rawValue: cipherName) else {
                throw KeyParseError.unsupportedFormat("Unsupported key cipher \(cipherName.prefix(32)).")
            }
            guard kdfName == "bcrypt" else { throw KeyParseError.unsupportedFormat("Unsupported key derivation \(kdfName.prefix(32)).") }
            guard let passphrase, !passphrase.isEmpty else { throw KeyParseError.passphraseRequired }
            var options = SSHWireReader(kdfOptions)
            let salt = try options.readString()
            let rounds = try options.readUInt32()
            guard rounds >= 1, rounds <= maxKDFRounds, section.count % cipher.blockSize == 0 else {
                throw KeyParseError.unsupportedFormat("Unsupported key derivation parameters.")
            }
            var derived = try BcryptPBKDF.derive(passphrase: Array(passphrase.utf8), salt: salt, rounds: rounds,
                                                 outputLength: cipher.keyLength + cipher.ivLength)
            defer { wipe(&derived) }
            let plain = try cipher.crypt(encrypt: false, key: Array(derived.prefix(cipher.keyLength)),
                                         iv: Array(derived.suffix(cipher.ivLength)), data: section)
            wipe(&section)
            section = plain
        } else {
            guard kdfName == "none" else { throw KeyParseError.unsupportedFormat("Unsupported key derivation \(kdfName.prefix(32)).") }
        }

        return try decodePrivateSection(section, publicBlob: publicBlob, wasEncrypted: isEncrypted)
    }

    private static func decodePrivateSection(_ section: [UInt8], publicBlob: [UInt8], wasEncrypted: Bool) throws -> SSHPrivateKey {
        var reader = SSHWireReader(section)
        let check1 = try reader.readUInt32()
        let check2 = try reader.readUInt32()
        guard check1 == check2 else {
            throw wasEncrypted ? KeyParseError.wrongPassphrase : KeyParseError.unsupportedFormat("The key file is corrupt.")
        }
        let typeName = try reader.readUTF8String()
        if let reason = SSHPublicKeyFormat.unsupportedReason(for: typeName) { throw KeyParseError.unsupportedAlgorithm(reason) }
        guard let algorithm = SSHKeyAlgorithm(rawValue: typeName) else {
            throw KeyParseError.unsupportedAlgorithm("Unsupported key type \(typeName.prefix(32)).")
        }

        let secret: SSHPrivateKey.Secret
        switch algorithm {
        case .ed25519:
            let publicKey = try reader.readString()
            let secretKey = try reader.readString()
            guard publicKey.count == 32, secretKey.count == 64, Array(secretKey.suffix(32)) == publicKey else {
                throw KeyParseError.unsupportedFormat("Malformed Ed25519 key.")
            }
            secret = .ed25519(seed: Data(secretKey.prefix(32)))
        case .ecdsaP256, .ecdsaP384, .ecdsaP521:
            let curveName = try reader.readUTF8String()
            _ = try reader.readString()  // public point; re-derived and compared below
            let scalar = try reader.readMPInt()
            guard let curve = ECDSACurve(algorithm: algorithm), curve.sshName == curveName, scalar.count <= curve.scalarLength else {
                throw KeyParseError.unsupportedFormat("Malformed ECDSA key.")
            }
            secret = .ecdsa(curve: curve, scalar: leftPad(scalar, to: curve.scalarLength))
        case .rsa:
            let modulus = try reader.readMPInt()
            let exponent = try reader.readMPInt()
            let privateExponent = try reader.readMPInt()
            let inverseQ = try reader.readMPInt()
            let primeP = try reader.readMPInt()
            let primeQ = try reader.readMPInt()
            secret = .rsa(RSAPrivateComponents(
                modulus: Data(modulus), publicExponent: Data(exponent), privateExponent: Data(privateExponent),
                inverseQ: Data(inverseQ), primeP: Data(primeP), primeQ: Data(primeQ)))
        }
        let comment = try reader.readUTF8String()
        // The remainder must be the 1, 2, 3... padding.
        let padding = try reader.readBytes(reader.remaining)
        guard padding.count < 16, padding.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) }) else {
            throw wasEncrypted ? KeyParseError.wrongPassphrase : KeyParseError.unsupportedFormat("The key file has invalid padding.")
        }

        let key = SSHPrivateKey(secret: secret, comment: comment)
        guard try Array(key.publicKeyBlob()) == publicBlob else {
            throw KeyParseError.unsupportedFormat("The public and private halves of the key do not match.")
        }
        return key
    }

    // MARK: Encoding

    /// Serializes `key` as armored `openssh-key-v1`.
    /// - Parameters:
    ///   - passphrase: when non-empty, encrypts with `aes256-ctr` + bcrypt-pbkdf (what `ssh-keygen` does by default).
    ///   - rounds: bcrypt rounds for the passphrase KDF.
    public static func encode(_ key: SSHPrivateKey, passphrase: String? = nil, rounds: UInt32 = defaultKDFRounds) throws -> Data {
        guard rounds >= 1, rounds <= maxKDFRounds else {
            throw KeyParseError.unsupportedFormat("bcrypt rounds must be between 1 and \(maxKDFRounds).")
        }
        let publicBlob = Array(try key.publicKeyBlob())
        let encrypting = !(passphrase?.isEmpty ?? true)
        let cipher = OpenSSHCipher.aes256ctr
        let blockSize = encrypting ? cipher.blockSize : 8

        var body = SSHWireWriter()
        var checkBytes = [UInt8](repeating: 0, count: 4)
        guard SecRandomCopyBytes(kSecRandomDefault, 4, &checkBytes) == errSecSuccess else {
            throw KeyParseError.unsupportedFormat("The system random number generator failed.")
        }
        let check = checkBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        body.writeUInt32(check)
        body.writeUInt32(check)
        body.writeString(key.algorithm.rawValue)
        switch key.secret {
        case .ed25519(let seed):
            let publicKey = try key.ed25519PrivateKey()!.publicKey.rawRepresentation
            body.writeString(Array(publicKey))
            body.writeString(Array(seed) + Array(publicKey))
        case .ecdsa(let curve, let scalar):
            body.writeString(curve.sshName)
            body.writeString(try SSHPrivateKey.publicPoint(curve: curve, scalar: scalar))
            body.writeMPInt(Array(scalar))
        case .rsa(let rsa):
            body.writeMPInt(Array(rsa.modulus))
            body.writeMPInt(Array(rsa.publicExponent))
            body.writeMPInt(Array(rsa.privateExponent))
            body.writeMPInt(Array(rsa.inverseQ))
            body.writeMPInt(Array(rsa.primeP))
            body.writeMPInt(Array(rsa.primeQ))
        }
        body.writeString(key.comment)
        var padding: UInt8 = 1
        var section = body.bytes
        while section.count % blockSize != 0 {
            section.append(padding)
            padding += 1
        }

        var kdfOptions = SSHWireWriter()
        var cipherName = "none"
        var kdfName = "none"
        if encrypting, let passphrase {
            var salt = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
                throw KeyParseError.unsupportedFormat("The system random number generator failed.")
            }
            var derived = try BcryptPBKDF.derive(passphrase: Array(passphrase.utf8), salt: salt, rounds: rounds,
                                                 outputLength: cipher.keyLength + cipher.ivLength)
            defer { wipe(&derived) }
            let encrypted = try cipher.crypt(encrypt: true, key: Array(derived.prefix(cipher.keyLength)),
                                             iv: Array(derived.suffix(cipher.ivLength)), data: section)
            wipe(&section)
            section = encrypted
            kdfOptions.writeString(salt)
            kdfOptions.writeUInt32(rounds)
            cipherName = cipher.rawValue
            kdfName = "bcrypt"
        }

        var out = SSHWireWriter()
        out.writeRaw(magic)
        out.writeString(cipherName)
        out.writeString(kdfName)
        out.writeString(kdfOptions.bytes)
        out.writeUInt32(1)
        out.writeString(publicBlob)
        out.writeString(section)
        wipe(&section)
        return armor(out.bytes)
    }

    /// Re-encodes stored (unencrypted) key bytes, optionally protecting them with a passphrase. Used for
    /// "Export private key" so a key can leave the device encrypted.
    public static func export(openSSHBytes: Data, passphrase: String?, rounds: UInt32 = defaultKDFRounds) throws -> Data {
        let key = try decode(openSSHBytes, passphrase: nil)
        return try encode(key, passphrase: passphrase, rounds: rounds)
    }

    private static func armor(_ container: [UInt8]) -> Data {
        let base64 = Data(container).base64EncodedString()
        var text = header + "\n"
        var index = base64.startIndex
        while index < base64.endIndex {
            let next = base64.index(index, offsetBy: 70, limitedBy: base64.endIndex) ?? base64.endIndex
            text += base64[index..<next] + "\n"
            index = next
        }
        text += footer + "\n"
        return Data(text.utf8)
    }

    static func leftPad(_ bytes: [UInt8], to length: Int) -> Data {
        guard bytes.count < length else { return Data(bytes) }
        return Data(repeating: 0, count: length - bytes.count) + Data(bytes)
    }
}
