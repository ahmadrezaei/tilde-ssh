import CryptoKit
import Foundation
import TildeCore

/// SHA-256 key fingerprints in the format `ssh-keygen -l` prints, and OpenSSH "randomart".
public enum KeyFingerprint {
    /// `"SHA256:"` followed by the unpadded base64 of SHA-256 over the public key blob.
    public static func sha256(publicKeyBlob: Data) -> String {
        "SHA256:" + unpaddedBase64(Data(SHA256.hash(data: publicKeyBlob)))
    }

    /// The raw 32 digest bytes behind a `SHA256:...` fingerprint, or `nil` if it is malformed.
    public static func digest(fromFingerprint fingerprint: String) -> Data? {
        guard fingerprint.hasPrefix("SHA256:") else { return nil }
        var base64 = String(fingerprint.dropFirst("SHA256:".count))
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64), data.count == 32 else { return nil }
        return data
    }

    static func unpaddedBase64(_ data: Data) -> String {
        var text = data.base64EncodedString()
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    /// A short form for lists: `SHA256:4f+HqTn1…Vw0` (first 8 characters after the prefix, last 3).
    public static func abbreviated(_ fingerprint: String) -> String {
        guard fingerprint.hasPrefix("SHA256:"), fingerprint.count > 7 + 14 else { return fingerprint }
        let body = fingerprint.dropFirst("SHA256:".count)
        return "SHA256:" + body.prefix(8) + "…" + body.suffix(3)
    }
}

/// OpenSSH's visual host key ("randomart") algorithm: the "drunken bishop" on a 17x9 board.
public enum RandomArt {
    private static let width = 17
    private static let height = 9
    private static let symbols = Array(" .o+=*BOX@%&#/^SE")

    /// Renders the board for a `SHA256:` fingerprint exactly like `ssh-keygen -lv` does, including the
    /// `+--[ED25519 256]--+` header and `+----[SHA256]-----+` footer. Returns `nil` for a malformed fingerprint.
    public static func render(fingerprintSHA256: String, algorithm: SSHKeyAlgorithm, bits: Int?) -> String? {
        guard let digest = KeyFingerprint.digest(fromFingerprint: fingerprintSHA256) else { return nil }
        let (typeName, size): (String, Int) = {
            switch algorithm {
            case .ed25519: ("ED25519", 256)
            case .ecdsaP256: ("ECDSA", 256)
            case .ecdsaP384: ("ECDSA", 384)
            case .ecdsaP521: ("ECDSA", 521)
            case .rsa: ("RSA", bits ?? 0)
            }
        }()

        var field = [[Int]](repeating: [Int](repeating: 0, count: height), count: width)
        var x = width / 2
        var y = height / 2
        let maxCount = symbols.count - 1  // 16
        for byte in digest {
            var input = byte
            for _ in 0..<4 {
                x += (input & 0x1) != 0 ? 1 : -1
                y += (input & 0x2) != 0 ? 1 : -1
                x = min(max(x, 0), width - 1)
                y = min(max(y, 0), height - 1)
                if field[x][y] < maxCount - 2 { field[x][y] += 1 }
                input >>= 2
            }
        }
        field[width / 2][height / 2] = maxCount - 1  // start: 'S'
        field[x][y] = maxCount                       // end: 'E'

        var lines = [border(title: "[\(typeName) \(size)]")]
        for row in 0..<height {
            var line = "|"
            for column in 0..<width { line.append(symbols[min(field[column][row], maxCount)]) }
            line.append("|")
            lines.append(line)
        }
        lines.append(border(title: "[SHA256]"))
        return lines.joined(separator: "\n")
    }

    private static func border(title: String) -> String {
        let leading = (width - title.count) / 2
        var line = "+" + String(repeating: "-", count: leading) + title
        let trailing = width - (line.count - 1)
        line += String(repeating: "-", count: max(trailing, 0)) + "+"
        return line
    }
}
