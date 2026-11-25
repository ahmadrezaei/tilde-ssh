import Foundation

/// Errors raised by the low-level readers. They are mapped to `KeyParseError` at the module boundary.
enum WireFormatError: Error {
    case truncated
    case malformed(String)
}

/// Reads the SSH wire primitives (RFC 4251): `uint32`, `string` and `mpint`.
struct SSHWireReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw WireFormatError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readUInt32() throws -> UInt32 {
        let b = try readBytes(4)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    mutating func readString() throws -> [UInt8] {
        let length = try readUInt32()
        guard length <= UInt32(remaining) else { throw WireFormatError.truncated }
        return try readBytes(Int(length))
    }

    mutating func readUTF8String() throws -> String {
        String(decoding: try readString(), as: UTF8.self)
    }

    /// Reads an `mpint` and returns its unsigned big-endian magnitude without leading zero bytes.
    mutating func readMPInt() throws -> [UInt8] {
        let raw = try readString()
        return Array(raw.drop(while: { $0 == 0 }))
    }
}

/// Writes the SSH wire primitives.
struct SSHWireWriter {
    private(set) var bytes: [UInt8] = []

    mutating func writeRaw(_ data: [UInt8]) { bytes.append(contentsOf: data) }

    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func writeString(_ data: [UInt8]) {
        writeUInt32(UInt32(data.count))
        bytes.append(contentsOf: data)
    }

    mutating func writeString(_ string: String) { writeString(Array(string.utf8)) }

    /// Writes an unsigned big-endian magnitude as an `mpint` (adds a leading zero when the top bit is set).
    mutating func writeMPInt(_ magnitude: [UInt8]) {
        let trimmed = Array(magnitude.drop(while: { $0 == 0 }))
        if let first = trimmed.first, first & 0x80 != 0 {
            writeUInt32(UInt32(trimmed.count + 1))
            bytes.append(0)
        } else {
            writeUInt32(UInt32(trimmed.count))
        }
        bytes.append(contentsOf: trimmed)
    }
}

/// Number of significant bits in an unsigned big-endian integer.
func bitLength(ofMagnitude magnitude: [UInt8]) -> Int {
    let trimmed = magnitude.drop(while: { $0 == 0 })
    guard let first = trimmed.first else { return 0 }
    return (trimmed.count - 1) * 8 + (8 - first.leadingZeroBitCount)
}

/// Overwrites an array with zeros in a way the optimizer is not allowed to elide.
func wipe(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress, raw.count > 0 else { return }
        memset_s(base, raw.count, 0, raw.count)
    }
    bytes.removeAll(keepingCapacity: false)
}
