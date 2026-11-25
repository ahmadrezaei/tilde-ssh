import Foundation

/// A private key as the SSH layer needs it for signing.
///
/// This is a deliberately small reader for **unencrypted** `openssh-key-v1` data. The full codec
/// (encrypted keys, PEM, serialisation) lives in `TildeSecurity`; keys reach the engine already decrypted
/// as `PrivateKeyMaterial`.
enum ParsedPrivateKey {
    /// 32-byte seed.
    case ed25519(seed: Data)
    /// Raw big-endian scalar (32, 48 or 66 bytes).
    case ecdsa(curve: ECDSACurve, scalar: Data)
    /// Big-endian magnitudes without leading zeros.
    case rsa(RSAComponents)
}

enum ECDSACurve: String {
    case p256 = "nistp256"
    case p384 = "nistp384"
    case p521 = "nistp521"

    var scalarLength: Int {
        switch self {
        case .p256: 32
        case .p384: 48
        case .p521: 66
        }
    }
}

struct RSAComponents: Equatable {
    var modulus: Data
    var publicExponent: Data
    var privateExponent: Data
    /// `q^-1 mod p`.
    var inverseQ: Data
    var primeP: Data
    var primeQ: Data
}

enum OpenSSHKeyError: Error, Equatable {
    case notOpenSSHKey
    case encrypted
    case malformed(String)
    case unsupportedAlgorithm(String)
}

enum OpenSSHKeyReader {
    private static let magic = Data("openssh-key-v1\0".utf8)
    private static let pemBegin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let pemEnd = "-----END OPENSSH PRIVATE KEY-----"
    private static let pkcs1Begin = "-----BEGIN RSA PRIVATE KEY-----"
    private static let pkcs1End = "-----END RSA PRIVATE KEY-----"

    /// `RSAPrivateKey ::= SEQUENCE { version, n, e, d, p, q, dp, dq, qinv }` (RFC 8017, A.1.2).
    private static func parsePKCS1(pem: String) throws -> ParsedPrivateKey {
        guard let begin = pem.range(of: pkcs1Begin), let end = pem.range(of: pkcs1End), begin.upperBound <= end.lowerBound else {
            throw OpenSSHKeyError.malformed("PEM armour")
        }
        let body = pem[begin.upperBound..<end.lowerBound]
        if body.contains("ENCRYPTED") { throw OpenSSHKeyError.encrypted }
        let base64 = body.split(whereSeparator: \.isNewline).filter { !$0.contains(":") }.joined()
        guard let der = Data(base64Encoded: base64) else { throw OpenSSHKeyError.malformed("base64") }

        var reader = DERReader(der)
        guard var sequence = reader.readSequence() else { throw OpenSSHKeyError.malformed("RSA sequence") }
        var integers: [Data] = []
        while let integer = sequence.readInteger() { integers.append(integer) }
        guard integers.count >= 9, integers[0].isEmpty || integers[0] == Data([0]) else { throw OpenSSHKeyError.malformed("RSA fields") }
        return .rsa(RSAComponents(
            modulus: integers[1], publicExponent: integers[2], privateExponent: integers[3],
            inverseQ: integers[8], primeP: integers[4], primeQ: integers[5]
        ))
    }

    /// Parses either the raw binary container (`openssh-key-v1\0...`) or the PEM-armoured text form.
    /// Traditional unencrypted RSA PEM (`BEGIN RSA PRIVATE KEY`, what `ssh-keygen -m PEM` writes) is accepted too.
    static func parse(_ data: Data) throws -> ParsedPrivateKey {
        if let text = String(data: data, encoding: .utf8), text.contains(pkcs1Begin) {
            return try parsePKCS1(pem: text)
        }
        let binary = try unarmor(data)
        var reader = SSHWireReader(binary)

        guard reader.readBytes(magic.count) == magic else { throw OpenSSHKeyError.notOpenSSHKey }
        guard let cipher = reader.readString(), let kdf = reader.readString(), reader.readData() != nil,
              let keyCount = reader.readUInt32() else {
            throw OpenSSHKeyError.malformed("header")
        }
        guard cipher == "none", kdf == "none" else { throw OpenSSHKeyError.encrypted }
        guard keyCount == 1 else { throw OpenSSHKeyError.malformed("expected exactly one key") }
        guard reader.readData() != nil, let privateSection = reader.readData() else {
            throw OpenSSHKeyError.malformed("key sections")
        }

        var section = SSHWireReader(privateSection)
        guard let check1 = section.readUInt32(), let check2 = section.readUInt32(), check1 == check2 else {
            throw OpenSSHKeyError.malformed("check integers differ")
        }
        guard let keyType = section.readString() else { throw OpenSSHKeyError.malformed("key type") }

        switch keyType {
        case "ssh-ed25519":
            guard let publicKey = section.readData(), publicKey.count == 32,
                  let secret = section.readData(), secret.count == 64 else {
                throw OpenSSHKeyError.malformed("ed25519 fields")
            }
            return .ed25519(seed: secret.prefix(32))

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard let curveName = section.readString(), let curve = ECDSACurve(rawValue: curveName),
                  section.readData() != nil,
                  let scalar = section.readMPInt() else {
                throw OpenSSHKeyError.malformed("ecdsa fields")
            }
            // The mpint drops leading zeros; CryptoKit wants the fixed-width scalar.
            guard scalar.count <= curve.scalarLength else { throw OpenSSHKeyError.malformed("ecdsa scalar") }
            let padded = Data(repeating: 0, count: curve.scalarLength - scalar.count) + scalar
            return .ecdsa(curve: curve, scalar: padded)

        case "ssh-rsa":
            guard let n = section.readMPInt(), let e = section.readMPInt(), let d = section.readMPInt(),
                  let iqmp = section.readMPInt(), let p = section.readMPInt(), let q = section.readMPInt() else {
                throw OpenSSHKeyError.malformed("rsa fields")
            }
            return .rsa(RSAComponents(modulus: n, publicExponent: e, privateExponent: d, inverseQ: iqmp, primeP: p, primeQ: q))

        default:
            throw OpenSSHKeyError.unsupportedAlgorithm(keyType)
        }
    }

    /// Returns the binary container, decoding the PEM armour when present.
    private static func unarmor(_ data: Data) throws -> Data {
        if data.starts(with: magic) { return data }
        guard let text = String(data: data, encoding: .utf8) else { throw OpenSSHKeyError.notOpenSSHKey }
        guard let begin = text.range(of: pemBegin), let end = text.range(of: pemEnd), begin.upperBound <= end.lowerBound else {
            throw OpenSSHKeyError.notOpenSSHKey
        }
        let body = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        guard let decoded = Data(base64Encoded: String(body)) else { throw OpenSSHKeyError.malformed("base64") }
        return decoded
    }
}

/// A cursor over SSH wire-format data (RFC 4251 section 5). Reads never trap on short input.
struct SSHWireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        // Rebase so indices start at zero regardless of how the Data was sliced.
        self.data = Data(data)
        self.offset = 0
    }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, data.count - offset >= count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// An SSH `string` as raw bytes.
    mutating func readData() -> Data? {
        guard let length = readUInt32() else { return nil }
        return readBytes(Int(length))
    }

    mutating func readString() -> String? {
        readData().flatMap { String(data: $0, encoding: .utf8) }
    }

    /// An `mpint` as an unsigned big-endian magnitude with leading zero bytes removed.
    mutating func readMPInt() -> Data? {
        guard let raw = readData() else { return nil }
        return raw.drop(while: { $0 == 0 })
    }
}

/// Just enough DER to read PKCS#1: definite-length SEQUENCE and INTEGER.
struct DERReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = Data(data) }

    private mutating func readLength() -> Int? {
        guard offset < data.count else { return nil }
        let first = Int(data[offset]); offset += 1
        if first < 0x80 { return first }
        let count = first & 0x7F
        guard count > 0, count <= 4, offset + count <= data.count else { return nil }
        var length = 0
        for _ in 0..<count { length = (length << 8) | Int(data[offset]); offset += 1 }
        return length
    }

    private mutating func readElement(tag: UInt8) -> Data? {
        guard offset < data.count, data[offset] == tag else { return nil }
        offset += 1
        guard let length = readLength(), offset + length <= data.count else { return nil }
        defer { offset += length }
        return data.subdata(in: offset..<(offset + length))
    }

    mutating func readSequence() -> DERReader? { readElement(tag: 0x30).map(DERReader.init) }

    /// An INTEGER as an unsigned magnitude without leading zeros.
    mutating func readInteger() -> Data? {
        readElement(tag: 0x02).map { Data($0.drop(while: { $0 == 0 })) }
    }
}
