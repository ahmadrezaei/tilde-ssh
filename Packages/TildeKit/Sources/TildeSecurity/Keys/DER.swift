import Foundation

/// One DER TLV node. Only what PKCS#1, PKCS#8, SEC1 and PBES2 need: single-byte tags, definite lengths.
struct DERNode {
    static let integer: UInt8 = 0x02
    static let bitString: UInt8 = 0x03
    static let octetString: UInt8 = 0x04
    static let null: UInt8 = 0x05
    static let oid: UInt8 = 0x06
    static let sequence: UInt8 = 0x30
    static let contextZero: UInt8 = 0xA0
    static let contextOne: UInt8 = 0xA1

    let tag: UInt8
    let content: [UInt8]

    /// Parses exactly one node from `bytes`; trailing garbage is rejected.
    static func parse(_ bytes: [UInt8]) throws -> DERNode {
        var offset = 0
        let node = try read(bytes, at: &offset)
        guard offset == bytes.count else { throw WireFormatError.malformed("trailing bytes after DER value") }
        return node
    }

    private static func read(_ bytes: [UInt8], at offset: inout Int) throws -> DERNode {
        guard offset + 2 <= bytes.count else { throw WireFormatError.truncated }
        let tag = bytes[offset]
        guard tag & 0x1F != 0x1F else { throw WireFormatError.malformed("multi-byte DER tag") }
        var length = Int(bytes[offset + 1])
        offset += 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, offset + count <= bytes.count else { throw WireFormatError.malformed("DER length") }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
        }
        guard length >= 0, offset + length <= bytes.count else { throw WireFormatError.truncated }
        defer { offset += length }
        return DERNode(tag: tag, content: Array(bytes[offset..<offset + length]))
    }

    /// The direct children of a constructed node (SEQUENCE, context-specific wrapper).
    func children() throws -> [DERNode] {
        var offset = 0
        var nodes: [DERNode] = []
        while offset < content.count {
            nodes.append(try DERNode.read(content, at: &offset))
        }
        return nodes
    }

    /// An INTEGER as an unsigned big-endian magnitude (leading zeros stripped).
    func unsignedInteger() throws -> [UInt8] {
        guard tag == DERNode.integer else { throw WireFormatError.malformed("expected INTEGER") }
        return Array(content.drop(while: { $0 == 0 }))
    }

    /// A small INTEGER as `Int`.
    func smallInteger() throws -> Int {
        let magnitude = try unsignedInteger()
        guard magnitude.count <= 4 else { throw WireFormatError.malformed("INTEGER too large") }
        return magnitude.reduce(0) { ($0 << 8) | Int($1) }
    }

    /// The payload of a BIT STRING without the unused-bits byte.
    func bitStringPayload() throws -> [UInt8] {
        guard tag == DERNode.bitString, let unused = content.first, unused == 0 else {
            throw WireFormatError.malformed("expected BIT STRING")
        }
        return Array(content.dropFirst())
    }

    func expect(_ expectedTag: UInt8, _ what: String) throws -> DERNode {
        guard tag == expectedTag else { throw WireFormatError.malformed("expected \(what)") }
        return self
    }
}

/// DER-encoded OBJECT IDENTIFIER contents for the algorithms Tilde recognises.
enum OID {
    static let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let ecPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    static let prime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    static let secp384r1: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x22]
    static let secp521r1: [UInt8] = [0x2B, 0x81, 0x04, 0x00, 0x23]
    static let ed25519: [UInt8] = [0x2B, 0x65, 0x70]

    static let pbes2: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D]
    static let pbkdf2: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C]
    static let hmacSHA1: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x07]
    static let hmacSHA224: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x08]
    static let hmacSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09]
    static let hmacSHA384: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x0A]
    static let hmacSHA512: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x0B]
    static let aes128CBC: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x02]
    static let aes192CBC: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x16]
    static let aes256CBC: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A]
    static let desEDE3CBC: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x03, 0x07]
}
