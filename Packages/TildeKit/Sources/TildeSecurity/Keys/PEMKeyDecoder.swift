import CommonCrypto
import Foundation
import TildeCore

/// Decodes the PEM / DER private key encodings OpenSSL and `ssh-keygen -m PEM|PKCS8` produce:
/// PKCS#1 `RSA PRIVATE KEY`, SEC1 `EC PRIVATE KEY`, PKCS#8 `PRIVATE KEY` (RSA, ECDSA, Ed25519), the legacy
/// `Proc-Type: 4,ENCRYPTED` encryption and PKCS#8 `ENCRYPTED PRIVATE KEY` (PBES2 with PBKDF2 and AES/3DES).
enum PEMKeyDecoder {
    struct Block {
        var label: String
        var headers: [String: String]
        var body: [UInt8]
    }

    /// Returns the first PEM block in `text`, or `nil` if there is none.
    static func firstBlock(in text: String) -> Block? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let startIndex = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("-----") }) else { return nil }
        let startLine = lines[startIndex]
        let label = String(startLine.dropFirst("-----BEGIN ".count).dropLast("-----".count))
        guard let endIndex = lines[(startIndex + 1)...].firstIndex(of: "-----END \(label)-----") else { return nil }

        var headers: [String: String] = [:]
        var bodyLines: [String] = []
        for line in lines[(startIndex + 1)..<endIndex] {
            if bodyLines.isEmpty, let colon = line.firstIndex(of: ":") {
                headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty {
                bodyLines.append(line)
            }
        }
        guard let body = Data(base64Encoded: bodyLines.joined()) else { return nil }
        return Block(label: label, headers: headers, body: Array(body))
    }

    /// Decodes a block into a key. `passphrase` is only used for encrypted blocks.
    static func decode(_ block: Block, passphrase: String?) throws -> SSHPrivateKey {
        do {
            switch block.label {
            case "RSA PRIVATE KEY":
                return try decodePKCS1or8Inner(block, passphrase: passphrase) { try pkcs1($0) }
            case "EC PRIVATE KEY":
                return try decodePKCS1or8Inner(block, passphrase: passphrase) { try sec1($0, curveHint: nil) }
            case "PRIVATE KEY":
                return try pkcs8(block.body)
            case "ENCRYPTED PRIVATE KEY":
                guard let passphrase, !passphrase.isEmpty else { throw KeyParseError.passphraseRequired }
                return try pkcs8(try decryptPKCS8(block.body, passphrase: passphrase))
            default:
                throw KeyParseError.unsupportedFormat("Unrecognised PEM block \(block.label.prefix(32)).")
            }
        } catch let error as KeyParseError {
            throw error
        } catch {
            // DER/ASN.1 failures on an encrypted block almost always mean a wrong passphrase.
            if block.headers["Proc-Type"]?.contains("ENCRYPTED") == true || block.label == "ENCRYPTED PRIVATE KEY" {
                throw KeyParseError.wrongPassphrase
            }
            throw KeyParseError.unsupportedFormat("The key file is truncated or corrupt.")
        }
    }

    // MARK: Legacy PEM encryption

    private static func decodePKCS1or8Inner(_ block: Block, passphrase: String?, parse: ([UInt8]) throws -> SSHPrivateKey) throws -> SSHPrivateKey {
        guard block.headers["Proc-Type"]?.contains("ENCRYPTED") == true else { return try parse(block.body) }
        guard let passphrase, !passphrase.isEmpty else { throw KeyParseError.passphraseRequired }
        guard let dek = block.headers["DEK-Info"] else { throw KeyParseError.unsupportedFormat("Encrypted PEM without DEK-Info.") }
        let parts = dek.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let iv = hexBytes(parts[1]) else { throw KeyParseError.unsupportedFormat("Malformed DEK-Info.") }
        let algorithm = parts[0].uppercased()
        let keyLength: Int
        let blockSize: Int
        switch algorithm {
        case "AES-128-CBC": (keyLength, blockSize) = (16, 16)
        case "AES-192-CBC": (keyLength, blockSize) = (24, 16)
        case "AES-256-CBC": (keyLength, blockSize) = (32, 16)
        case "DES-EDE3-CBC": (keyLength, blockSize) = (24, 8)
        default: throw KeyParseError.unsupportedFormat("Unsupported PEM cipher \(algorithm.prefix(24)).")
        }
        guard iv.count == blockSize, block.body.count % blockSize == 0, !block.body.isEmpty else {
            throw KeyParseError.wrongPassphrase
        }
        var key = LegacyKDF.evpBytesToKeyMD5(passphrase: Array(passphrase.utf8), salt: Array(iv.prefix(8)), keyLength: keyLength)
        defer { wipe(&key) }
        var plain: [UInt8] = blockSize == 16
            ? try AESCrypto.cbc(encrypt: false, key: key, iv: iv, data: block.body)
            : try AESCrypto.tripleDESCBC(encrypt: false, key: key, iv: iv, data: block.body)
        defer { wipe(&plain) }
        guard let unpadded = LegacyKDF.removePKCS7Padding(plain, blockSize: blockSize) else { throw KeyParseError.wrongPassphrase }
        do {
            return try parse(unpadded)
        } catch {
            throw KeyParseError.wrongPassphrase
        }
    }

    private static func hexBytes(_ string: String) -> [UInt8]? {
        guard string.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    // MARK: PKCS#1 / SEC1 / PKCS#8

    /// `RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }`
    static func pkcs1(_ der: [UInt8]) throws -> SSHPrivateKey {
        let fields = try DERNode.parse(der).expect(DERNode.sequence, "SEQUENCE").children()
        guard fields.count >= 9 else { throw WireFormatError.malformed("RSA key has too few fields") }
        guard try fields[0].smallInteger() == 0 else { throw KeyParseError.unsupportedFormat("Multi-prime RSA keys are not supported.") }
        let components = RSAPrivateComponents(
            modulus: Data(try fields[1].unsignedInteger()),
            publicExponent: Data(try fields[2].unsignedInteger()),
            privateExponent: Data(try fields[3].unsignedInteger()),
            inverseQ: Data(try fields[8].unsignedInteger()),
            primeP: Data(try fields[4].unsignedInteger()),
            primeQ: Data(try fields[5].unsignedInteger()))
        return SSHPrivateKey(secret: .rsa(components))
    }

    /// `ECPrivateKey ::= SEQUENCE { version 1, privateKey OCTET STRING, [0] parameters, [1] publicKey }`
    static func sec1(_ der: [UInt8], curveHint: ECDSACurve?) throws -> SSHPrivateKey {
        let fields = try DERNode.parse(der).expect(DERNode.sequence, "SEQUENCE").children()
        guard fields.count >= 2, try fields[0].smallInteger() == 1 else { throw WireFormatError.malformed("bad ECPrivateKey") }
        let scalar = try fields[1].expect(DERNode.octetString, "OCTET STRING").content
        var curve = curveHint
        var pointLength: Int?
        for field in fields.dropFirst(2) {
            if field.tag == DERNode.contextZero, let oid = try field.children().first, oid.tag == DERNode.oid {
                if let named = ECDSACurve(oid: oid.content) { curve = named } else { throw KeyParseError.unsupportedAlgorithm("Unsupported elliptic curve.") }
            } else if field.tag == DERNode.contextOne, let bits = try field.children().first {
                pointLength = try bits.bitStringPayload().count
            }
        }
        if curve == nil { curve = ECDSACurve(pointLength: pointLength, scalarLength: scalar.count) }
        guard let curve, scalar.count <= curve.scalarLength else { throw KeyParseError.unsupportedAlgorithm("Unsupported elliptic curve.") }
        return SSHPrivateKey(secret: .ecdsa(curve: curve, scalar: OpenSSHPrivateKeyCodec.leftPad(scalar, to: curve.scalarLength)))
    }

    /// `PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, OCTET STRING privateKey, ... }`
    static func pkcs8(_ der: [UInt8]) throws -> SSHPrivateKey {
        let fields = try DERNode.parse(der).expect(DERNode.sequence, "SEQUENCE").children()
        guard fields.count >= 3, try fields[0].smallInteger() == 0 else { throw WireFormatError.malformed("bad PrivateKeyInfo") }
        let algorithm = try fields[1].expect(DERNode.sequence, "AlgorithmIdentifier").children()
        guard let oid = algorithm.first, oid.tag == DERNode.oid else { throw WireFormatError.malformed("missing algorithm OID") }
        let inner = try fields[2].expect(DERNode.octetString, "OCTET STRING").content

        switch oid.content {
        case OID.rsaEncryption:
            return try pkcs1(inner)
        case OID.ecPublicKey:
            var hint: ECDSACurve?
            if algorithm.count > 1, algorithm[1].tag == DERNode.oid {
                guard let named = ECDSACurve(oid: algorithm[1].content) else { throw KeyParseError.unsupportedAlgorithm("Unsupported elliptic curve.") }
                hint = named
            }
            return try sec1(inner, curveHint: hint)
        case OID.ed25519:
            let seed = try DERNode.parse(inner).expect(DERNode.octetString, "OCTET STRING").content
            guard seed.count == 32 else { throw WireFormatError.malformed("bad Ed25519 seed") }
            return SSHPrivateKey(secret: .ed25519(seed: Data(seed)))
        default:
            throw KeyParseError.unsupportedAlgorithm("Unsupported PKCS#8 key algorithm.")
        }
    }

    // MARK: PKCS#8 PBES2

    /// `EncryptedPrivateKeyInfo` with PBES2 (PBKDF2 + AES-CBC / 3DES-CBC). Returns the inner PKCS#8 DER.
    static func decryptPKCS8(_ der: [UInt8], passphrase: String) throws -> [UInt8] {
        let top = try DERNode.parse(der).expect(DERNode.sequence, "SEQUENCE").children()
        guard top.count == 2 else { throw WireFormatError.malformed("bad EncryptedPrivateKeyInfo") }
        let scheme = try top[0].expect(DERNode.sequence, "AlgorithmIdentifier").children()
        guard scheme.count == 2, scheme[0].content == OID.pbes2 else {
            throw KeyParseError.unsupportedFormat("Unsupported PKCS#8 encryption scheme (only PBES2 is supported).")
        }
        let pbes2 = try scheme[1].expect(DERNode.sequence, "PBES2-params").children()
        guard pbes2.count == 2 else { throw WireFormatError.malformed("bad PBES2 parameters") }

        // Key derivation function.
        let kdf = try pbes2[0].expect(DERNode.sequence, "KDF").children()
        guard kdf.count == 2, kdf[0].content == OID.pbkdf2 else {
            throw KeyParseError.unsupportedFormat("Unsupported PKCS#8 key derivation (only PBKDF2 is supported).")
        }
        let kdfParams = try kdf[1].expect(DERNode.sequence, "PBKDF2-params").children()
        guard kdfParams.count >= 2 else { throw WireFormatError.malformed("bad PBKDF2 parameters") }
        let salt = try kdfParams[0].expect(DERNode.octetString, "salt").content
        let iterations = try kdfParams[1].smallInteger()
        var prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        for extra in kdfParams.dropFirst(2) where extra.tag == DERNode.sequence {
            guard let prfOID = try extra.children().first?.content else { continue }
            switch prfOID {
            case OID.hmacSHA1: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            case OID.hmacSHA224: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA224)
            case OID.hmacSHA256: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            case OID.hmacSHA384: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
            case OID.hmacSHA512: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            default: throw KeyParseError.unsupportedFormat("Unsupported PBKDF2 hash.")
            }
        }
        guard iterations >= 1, iterations <= 10_000_000 else { throw KeyParseError.unsupportedFormat("Unsupported PBKDF2 iteration count.") }

        // Encryption scheme.
        let cipher = try pbes2[1].expect(DERNode.sequence, "encryption scheme").children()
        guard cipher.count == 2 else { throw WireFormatError.malformed("bad encryption scheme") }
        let iv = try cipher[1].expect(DERNode.octetString, "IV").content
        let keyLength: Int
        let blockSize: Int
        let isAES: Bool
        switch cipher[0].content {
        case OID.aes128CBC: (keyLength, blockSize, isAES) = (16, 16, true)
        case OID.aes192CBC: (keyLength, blockSize, isAES) = (24, 16, true)
        case OID.aes256CBC: (keyLength, blockSize, isAES) = (32, 16, true)
        case OID.desEDE3CBC: (keyLength, blockSize, isAES) = (24, 8, false)
        default: throw KeyParseError.unsupportedFormat("Unsupported PKCS#8 cipher.")
        }
        let encrypted = try top[1].expect(DERNode.octetString, "encrypted data").content
        guard iv.count == blockSize, !encrypted.isEmpty, encrypted.count % blockSize == 0 else { throw KeyParseError.wrongPassphrase }

        var key = try LegacyKDF.pbkdf2(passphrase: Array(passphrase.utf8), salt: salt, iterations: iterations, prf: prf, keyLength: keyLength)
        defer { wipe(&key) }
        var plain = isAES
            ? try AESCrypto.cbc(encrypt: false, key: key, iv: iv, data: encrypted)
            : try AESCrypto.tripleDESCBC(encrypt: false, key: key, iv: iv, data: encrypted)
        defer { wipe(&plain) }
        guard let unpadded = LegacyKDF.removePKCS7Padding(plain, blockSize: blockSize) else { throw KeyParseError.wrongPassphrase }
        return unpadded
    }
}
