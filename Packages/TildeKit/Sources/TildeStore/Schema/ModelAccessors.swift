import Foundation
import SwiftData
import TildeCore

// Typed accessors over the raw-string columns. The raw strings are what CloudKit stores, so they stay
// forward compatible: an unknown value written by a newer app version reads back as a safe default here.

/// `KnownHost.statusRaw`.
public enum KnownHostStatus: String, Sendable, CaseIterable {
    case trusted
    /// The user forgot the pin. Revoked rows are ignored by lookups.
    case revoked
    /// Two devices pinned different keys for the same endpoint and algorithm. Never auto-resolved.
    case conflicted
}

/// `KnownHost.sourceRaw`.
public enum KnownHostSource: String, Sendable, CaseIterable {
    case tofu, imported, manual
}

/// `Snippet.runModeRaw`.
public enum SnippetRunMode: String, Sendable, CaseIterable {
    case insert
    case insertAndReturn
}

/// `SSHKeyRecord.sourceRaw`.
public enum SSHKeySource: String, Sendable, CaseIterable {
    case generated, imported, secureEnclave
}

public extension Server {
    /// Typed `environmentRaw`; unknown values read as `.none`.
    var environment: ServerEnvironment {
        get { ServerEnvironment(rawValue: environmentRaw) ?? .none }
        set { environmentRaw = newValue.rawValue }
    }

    /// Typed `authMethodRaw`; unknown values read as `.key`.
    var authMethod: AuthMethod {
        get { AuthMethod(rawValue: authMethodRaw) ?? .key }
        set { authMethodRaw = newValue.rawValue }
    }

    /// Decoded `envVarsJSON`. Setting an empty dictionary clears the column.
    var envVars: [String: String] {
        get {
            guard let data = envVarsJSON?.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return decoded
        }
        set {
            guard !newValue.isEmpty else { envVarsJSON = nil; return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            envVarsJSON = (try? encoder.encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// The tags as a non-optional array.
    var tagList: [Tag] { tags ?? [] }

    /// `host` trimmed and lowercased, the form stored and matched on.
    static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `username@host[:port]` as shown in the list's second line.
    var displayTarget: String {
        let base = username.isEmpty ? host : "\(username)@\(host)"
        return port == 22 ? base : "\(base):\(port)"
    }

    /// The target this server connects to.
    var connectionTarget: ConnectionTarget { ConnectionTarget(host: host, port: port, username: username) }
}

public extension KnownHost {
    /// Typed `statusRaw`. Fails closed: a status written by a newer app version that this version does not
    /// understand reads as `.conflicted`, so lookups refuse to auto-trust the pin.
    var status: KnownHostStatus {
        get { KnownHostStatus(rawValue: statusRaw) ?? .conflicted }
        set { statusRaw = newValue.rawValue }
    }

    /// Typed `sourceRaw`.
    var source: KnownHostSource {
        get { KnownHostSource(rawValue: sourceRaw) ?? .tofu }
        set { sourceRaw = newValue.rawValue }
    }

    /// The pinned key as the contract's value type.
    var hostKey: HostKey {
        HostKey(algorithm: algorithm, blobBase64: publicKeyBase64, fingerprintSHA256: fingerprintSHA256)
    }

    /// The pin as the contract's value type.
    var pinned: PinnedHostKey {
        PinnedHostKey(key: hostKey, firstSeenAt: firstSeenAt, trustedOnDevice: trustedOnDevice)
    }

    /// Decoded `historyJSON` (previous keys, oldest first).
    var history: [KnownHostHistoryEntry] {
        get {
            guard let data = historyJSON?.data(using: .utf8) else { return [] }
            return (try? KnownHostHistoryEntry.makeDecoder().decode([KnownHostHistoryEntry].self, from: data)) ?? []
        }
        set {
            guard !newValue.isEmpty else { historyJSON = nil; return }
            historyJSON = (try? KnownHostHistoryEntry.makeEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}

/// One superseded pin, kept in `KnownHost.historyJSON` so the changed-key screen can show what was trusted before.
public struct KnownHostHistoryEntry: Codable, Hashable, Sendable {
    public var algorithm: String
    public var fingerprintSHA256: String
    public var firstSeenAt: Date
    public var replacedAt: Date

    public init(algorithm: String, fingerprintSHA256: String, firstSeenAt: Date, replacedAt: Date) {
        self.algorithm = algorithm
        self.fingerprintSHA256 = fingerprintSHA256
        self.firstSeenAt = firstSeenAt
        self.replacedAt = replacedAt
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public extension Snippet {
    /// Typed `runModeRaw`; unknown values read as `.insert`.
    var runMode: SnippetRunMode {
        get { SnippetRunMode(rawValue: runModeRaw) ?? .insert }
        set { runModeRaw = newValue.rawValue }
    }
}

public extension SSHKeyRecord {
    /// Typed `sourceRaw`.
    var source: SSHKeySource {
        get { SSHKeySource(rawValue: sourceRaw) ?? .generated }
        set { sourceRaw = newValue.rawValue }
    }

    /// Typed `algorithmRaw`, nil for an algorithm this version does not know.
    var algorithm: SSHKeyAlgorithm? { SSHKeyAlgorithm(rawValue: algorithmRaw) }

    /// The Keychain reference of the private key.
    var privateSecretRef: SecretRef { SecretRef(kind: .privateKey, id: privateSecretID) }
}

extension HostEndpoint {
    /// The endpoint as the store keys it: whitespace trimmed and IPv6 brackets removed (`[::1]` and `::1`
    /// are the same host), so `canonical` never produces `[[::1]]:2222`.
    var normalized: HostEndpoint {
        var host = self.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 { host = String(host.dropFirst().dropLast()) }
        return HostEndpoint(host: host, port: port)
    }
}

/// Orders by creation date, then by `id`, so every device picks the same survivor when it merges duplicates.
func isOlder<T>(_ lhs: T, than rhs: T, created: KeyPath<T, Date>, id: KeyPath<T, UUID>) -> Bool {
    let (l, r) = (lhs[keyPath: created], rhs[keyPath: created])
    if l != r { return l < r }
    return lhs[keyPath: id].uuidString < rhs[keyPath: id].uuidString
}
