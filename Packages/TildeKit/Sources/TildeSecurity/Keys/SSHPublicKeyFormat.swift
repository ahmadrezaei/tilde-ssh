import Foundation
import TildeCore

/// Parsing and formatting of SSH public keys (the `ssh-ed25519 AAAA... comment` line and its binary blob).
enum SSHPublicKeyFormat {
    /// Builds the `authorized_keys` style line.
    static func line(algorithm: SSHKeyAlgorithm, blob: Data, comment: String) -> String {
        let base = "\(algorithm.rawValue) \(blob.base64EncodedString())"
        let cleaned = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return cleaned.isEmpty ? base : base + " " + cleaned
    }

    static func info(algorithm: SSHKeyAlgorithm, bits: Int?, blob: Data, comment: String) -> PublicKeyInfo {
        PublicKeyInfo(
            algorithm: algorithm,
            bits: algorithm == .rsa ? bits : nil,
            openSSH: line(algorithm: algorithm, blob: blob, comment: comment),
            fingerprintSHA256: KeyFingerprint.sha256(publicKeyBlob: blob),
            comment: comment.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Algorithm names OpenSSH knows but Tilde deliberately does not support.
    static func unsupportedReason(for algorithmName: String) -> String? {
        if algorithmName == "ssh-dss" { return "DSA is insecure and disabled in OpenSSH." }
        if algorithmName.hasPrefix("sk-") { return "Hardware security keys (FIDO) are not supported." }
        if algorithmName.hasSuffix("-cert-v01@openssh.com") { return "OpenSSH certificates are not supported." }
        return nil
    }

    /// Validates a public key blob and returns its algorithm and (for RSA) modulus size.
    static func parseBlob(_ blob: [UInt8]) throws -> (algorithm: SSHKeyAlgorithm, bits: Int?) {
        do {
            var reader = SSHWireReader(blob)
            let name = try reader.readUTF8String()
            if let reason = unsupportedReason(for: name) { throw KeyParseError.unsupportedAlgorithm(reason) }
            guard let algorithm = SSHKeyAlgorithm(rawValue: name) else {
                throw KeyParseError.unsupportedAlgorithm("Unsupported key type \(sanitised(name)).")
            }
            switch algorithm {
            case .ed25519:
                guard try reader.readString().count == 32 else { throw KeyParseError.unsupportedFormat("Malformed Ed25519 public key.") }
                return (algorithm, nil)
            case .ecdsaP256, .ecdsaP384, .ecdsaP521:
                let curveName = try reader.readUTF8String()
                let point = try reader.readString()
                guard let curve = ECDSACurve(algorithm: algorithm), curve.sshName == curveName, point.count == curve.pointLength, point.first == 0x04 else {
                    throw KeyParseError.unsupportedFormat("Malformed ECDSA public key.")
                }
                return (algorithm, nil)
            case .rsa:
                let exponent = try reader.readMPInt()
                let modulus = try reader.readMPInt()
                guard !exponent.isEmpty, !modulus.isEmpty else { throw KeyParseError.unsupportedFormat("Malformed RSA public key.") }
                return (algorithm, bitLength(ofMagnitude: modulus))
            }
        } catch let error as KeyParseError {
            throw error
        } catch {
            throw KeyParseError.unsupportedFormat("The public key data is truncated or malformed.")
        }
    }

    static func parseLine(_ line: String) throws -> PublicKeyInfo {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let parts = firstLine.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else {
            throw KeyParseError.unsupportedFormat("Not an OpenSSH public key line (expected: type base64 [comment]).")
        }
        let algorithmName = String(parts[0])
        if let reason = unsupportedReason(for: algorithmName) { throw KeyParseError.unsupportedAlgorithm(reason) }
        guard let declared = SSHKeyAlgorithm(rawValue: algorithmName) else {
            throw KeyParseError.unsupportedAlgorithm("Unsupported key type \(sanitised(algorithmName)).")
        }
        guard let blob = Data(base64Encoded: String(parts[1])) else {
            throw KeyParseError.unsupportedFormat("The public key is not valid base64.")
        }
        let (actual, bits) = try parseBlob(Array(blob))
        guard actual == declared else {
            throw KeyParseError.unsupportedFormat("The key type in the line does not match the key data.")
        }
        let comment = parts.count > 2 ? String(parts[2]) : ""
        return info(algorithm: declared, bits: bits, blob: blob, comment: comment)
    }

    /// Keeps attacker-controlled names short and printable before they reach an error message.
    private static func sanitised(_ name: String) -> String {
        let printable = name.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }
        return String(String.UnicodeScalarView(printable.prefix(64)))
    }
}
