import CryptoKit
import Foundation
import Observation
import TildeCore

// MARK: - Parsing (pure, testable)

/// One host key from a `known_hosts` file, ready to pin.
public struct KnownHostsEntry: Identifiable, Equatable, Sendable {
    /// Unique within one parse result.
    public let id: Int
    /// 1-based line in the source file (several entries can share a line: `a.example.com,10.0.0.4 ssh-ed25519 ...`).
    public let line: Int
    public let endpoint: HostEndpoint
    public let key: HostKey
}

/// A line (or part of one) the importer left out, with the reason.
public struct KnownHostsSkip: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// `|1|salt|hash` entries cannot be turned back into a host name.
        case hashedHost
        /// `*`, `?` or `!` patterns do not name one host.
        case wildcardPattern(String)
        /// `@cert-authority` and `@revoked` lines are not host pins.
        case marker(String)
        /// Key types Tilde cannot negotiate (`ssh-dss`, `sk-*`, certificates).
        case unsupportedAlgorithm(String)
        /// The line has too few fields, the key is not valid base64, or the key does not match its declared type.
        case malformed
    }

    public let line: Int
    public let reason: Reason
}

/// The result of reading a whole file.
public struct KnownHostsParseResult: Equatable, Sendable {
    public var entries: [KnownHostsEntry]
    public var skipped: [KnownHostsSkip]

    /// How many hashed entries were skipped.
    public var hashedCount: Int { skipped.filter { $0.reason == .hashedHost }.count }
    /// Skips other than hashed hosts, for the "also skipped" note.
    public var otherSkips: [KnownHostsSkip] { skipped.filter { $0.reason != .hashedHost } }
}

/// Reads OpenSSH `known_hosts` files.
///
/// Supported: plain host names and addresses, `[host]:port`, comma-separated host lists, bracketed and bare IPv6,
/// comments and blank lines. Skipped with a reason: hashed hosts (`|1|...`), wildcard patterns, markers, and key
/// types the app cannot use. Keys are validated structurally (base64, and the type embedded in the key blob must
/// match the type named on the line).
public enum KnownHostsParser {
    /// Host key algorithms Tilde can negotiate and pin.
    public static let supportedAlgorithms: Set<String> = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa",
    ]

    /// Parses `text`.
    /// - Parameter fingerprint: computes `SHA256:...` from the raw key blob. Defaults to the OpenSSH format.
    public static func parse(_ text: String, fingerprint: (Data) -> String = sha256Fingerprint) -> KnownHostsParseResult {
        var entries: [KnownHostsEntry] = []
        var skipped: [KnownHostsSkip] = []
        var seen = Set<String>()
        var lineNumber = 0

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            var fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if let first = fields.first, first.hasPrefix("@") {
                skipped.append(KnownHostsSkip(line: lineNumber, reason: .marker(first)))
                continue
            }
            guard fields.count >= 3 else {
                skipped.append(KnownHostsSkip(line: lineNumber, reason: .malformed))
                continue
            }
            let hostField = fields.removeFirst()
            let algorithm = fields.removeFirst()
            let base64 = fields.removeFirst()

            guard supportedAlgorithms.contains(algorithm) else {
                skipped.append(KnownHostsSkip(line: lineNumber, reason: .unsupportedAlgorithm(algorithm)))
                continue
            }
            guard let blob = Data(base64Encoded: base64), blobAlgorithm(blob) == algorithm else {
                skipped.append(KnownHostsSkip(line: lineNumber, reason: .malformed))
                continue
            }
            let key = HostKey(algorithm: algorithm, blobBase64: base64, fingerprintSHA256: fingerprint(blob))

            if hostField.hasPrefix("|") {
                skipped.append(KnownHostsSkip(line: lineNumber, reason: .hashedHost))
                continue
            }
            for pattern in hostField.split(separator: ",").map(String.init) {
                if pattern.hasPrefix("|") {
                    skipped.append(KnownHostsSkip(line: lineNumber, reason: .hashedHost))
                } else if pattern.contains("*") || pattern.contains("?") || pattern.hasPrefix("!") {
                    skipped.append(KnownHostsSkip(line: lineNumber, reason: .wildcardPattern(pattern)))
                } else if let endpoint = endpoint(from: pattern) {
                    let signature = "\(endpoint.canonical)|\(algorithm)|\(base64)"
                    guard seen.insert(signature).inserted else { continue }
                    entries.append(KnownHostsEntry(id: entries.count, line: lineNumber, endpoint: endpoint, key: key))
                } else {
                    skipped.append(KnownHostsSkip(line: lineNumber, reason: .malformed))
                }
            }
        }
        return KnownHostsParseResult(entries: entries, skipped: skipped)
    }

    /// `host`, `[host]:port`, `[v6]`, or a bare IPv6 address.
    static func endpoint(from pattern: String) -> HostEndpoint? {
        if pattern.hasPrefix("[") {
            guard let close = pattern.firstIndex(of: "]") else { return nil }
            let host = String(pattern[pattern.index(after: pattern.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let rest = pattern[pattern.index(after: close)...]
            if rest.isEmpty { return HostEndpoint(host: host, port: 22) }
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return nil }
            return HostEndpoint(host: host, port: port)
        }
        return pattern.isEmpty ? nil : HostEndpoint(host: pattern, port: 22)
    }

    /// Reads the key type string at the start of an SSH public-key blob (`uint32 length, bytes`).
    static func blobAlgorithm(_ blob: Data) -> String? {
        guard blob.count >= 4 else { return nil }
        let bytes = [UInt8](blob.prefix(4))
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length > 0, blob.count >= 4 + length else { return nil }
        return String(data: blob.subdata(in: 4..<(4 + length)), encoding: .utf8)
    }

    /// `SHA256:` plus the unpadded base64 digest, as `ssh-keygen -lf` prints it.
    public static func sha256Fingerprint(_ blob: Data) -> String {
        var text = Data(SHA256.hash(data: blob)).base64EncodedString()
        while text.hasSuffix("=") { text.removeLast() }
        return "SHA256:" + text
    }
}

// MARK: - Model

/// How an entry relates to what is already pinned.
public enum KnownHostsImportStatus: Equatable, Sendable {
    /// Not pinned yet: can be imported.
    case new
    /// The same key is already pinned.
    case alreadyTrusted
    /// A different key is pinned for this host. Never overwritten by an import.
    case conflict
}

/// What the import did.
public struct KnownHostsImportSummary: Equatable, Sendable {
    public var imported: Int
    public var alreadyTrusted: Int
    public var conflicts: Int
    public var failed: Int
    /// Hashed entries that could not be read.
    public var hashedSkipped: Int

    public init(imported: Int = 0, alreadyTrusted: Int = 0, conflicts: Int = 0, failed: Int = 0, hashedSkipped: Int = 0) {
        self.imported = imported
        self.alreadyTrusted = alreadyTrusted
        self.conflicts = conflicts
        self.failed = failed
        self.hashedSkipped = hashedSkipped
    }
}

/// State behind `KnownHostsImportView`.
@MainActor
@Observable
public final class KnownHostsImportModel {
    /// File name shown in the header.
    public private(set) var sourceName: String?
    /// Everything parsed from the file.
    public private(set) var result = KnownHostsParseResult(entries: [], skipped: [])
    /// Status per entry id, filled by `classify(using:)`.
    public private(set) var statuses: [Int: KnownHostsImportStatus] = [:]
    /// Checked entry ids. Only `.new` entries can be checked.
    public var selection: Set<Int> = []
    /// A user-facing error, if the file could not be used.
    public private(set) var errorMessage: String?
    /// The outcome after `importSelected(using:)`.
    public private(set) var summary: KnownHostsImportSummary?
    /// True while `classify` or `importSelected` is running.
    public private(set) var isWorking = false

    /// Creates an empty model.
    public init() {}

    /// Parses `text` and clears the previous state. Call `classify(using:)` next.
    public func load(text: String, sourceName: String?) {
        self.sourceName = sourceName
        result = KnownHostsParser.parse(text)
        statuses = [:]
        selection = []
        summary = nil
        errorMessage = result.entries.isEmpty
            ? (result.hashedCount > 0
                ? "Every entry in this file is hashed (HashKnownHosts), so the host names can't be recovered."
                : "No host keys found in this file.")
            : nil
    }

    /// Records a file read failure.
    public func fail(_ error: any Error) { errorMessage = error.localizedDescription }

    /// Compares every entry with the pins in `store` and pre-checks the new ones.
    public func classify(using store: any KnownHostsStore) async {
        isWorking = true
        defer { isWorking = false }
        var result: [Int: KnownHostsImportStatus] = [:]
        for entry in self.result.entries {
            switch await store.lookup(entry.endpoint, presented: entry.key) {
            case .trusted: result[entry.id] = .alreadyTrusted
            case .unknown: result[entry.id] = .new
            case .mismatch, .conflicted: result[entry.id] = .conflict
            }
        }
        statuses = result
        selection = Set(result.filter { $0.value == .new }.keys)
    }

    /// Entries with the given status, in file order.
    public func entries(_ status: KnownHostsImportStatus) -> [KnownHostsEntry] {
        result.entries.filter { statuses[$0.id] == status }
    }

    /// Pins every checked entry through `store`. Existing pins are never replaced.
    @discardableResult
    public func importSelected(using store: any KnownHostsStore) async -> KnownHostsImportSummary {
        isWorking = true
        defer { isWorking = false }
        var summary = KnownHostsImportSummary(
            alreadyTrusted: entries(.alreadyTrusted).count,
            conflicts: entries(.conflict).count,
            hashedSkipped: result.hashedCount
        )
        for entry in result.entries where selection.contains(entry.id) && statuses[entry.id] == .new {
            do {
                try await store.trust(entry.key, for: entry.endpoint, replacing: false)
                summary.imported += 1
            } catch {
                summary.failed += 1
            }
        }
        self.summary = summary
        return summary
    }
}
