import Foundation

// MARK: - Host keys (store, validator, prompt UI)

/// A host and port, with OpenSSH `known_hosts` canonicalisation.
public struct HostEndpoint: Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 22) {
        self.host = host
        self.port = port
    }

    /// `host` for port 22, otherwise `[host]:port` (lowercased), as OpenSSH writes it.
    public var canonical: String { port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)" }
}

/// A host key as presented by a server.
public struct HostKey: Hashable, Sendable {
    public var algorithm: String
    public var blobBase64: String
    public var fingerprintSHA256: String

    public init(algorithm: String, blobBase64: String, fingerprintSHA256: String) {
        self.algorithm = algorithm
        self.blobBase64 = blobBase64
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

/// The result of checking a presented key against pinned keys.
public enum HostKeyLookup: Sendable, Equatable {
    case trusted
    case unknown
    /// A different key is pinned for this endpoint and algorithm.
    case mismatch(pinned: [PinnedHostKey])
    /// Two devices pinned different keys for the same endpoint; never auto-resolved.
    case conflicted(candidates: [PinnedHostKey])
}

public struct PinnedHostKey: Hashable, Sendable {
    public var key: HostKey
    public var firstSeenAt: Date
    public var trustedOnDevice: String

    public init(key: HostKey, firstSeenAt: Date, trustedOnDevice: String) {
        self.key = key
        self.firstSeenAt = firstSeenAt
        self.trustedOnDevice = trustedOnDevice
    }
}

public protocol KnownHostsStore: Sendable {
    func lookup(_ endpoint: HostEndpoint, presented: HostKey) async -> HostKeyLookup
    /// Pins `key`. With `replacing: true` the previous pin is moved into the record's history.
    func trust(_ key: HostKey, for endpoint: HostEndpoint, replacing: Bool) async throws
    /// Updates `lastSeenAt`, throttled to limit sync churn.
    func touch(_ endpoint: HostEndpoint) async
}

/// What the engine asks the UI to decide (TOFU sheet, or the changed-key takeover).
public struct HostKeyChallenge: Sendable, Identifiable {
    public let id: UUID
    public let endpoint: HostEndpoint
    public let serverName: String?
    public let presented: HostKey
    public let lookup: HostKeyLookup

    public init(id: UUID = UUID(), endpoint: HostEndpoint, serverName: String?, presented: HostKey, lookup: HostKeyLookup) {
        self.id = id
        self.endpoint = endpoint
        self.serverName = serverName
        self.presented = presented
        self.lookup = lookup
    }
}

public enum HostKeyDecision: Sendable, Equatable {
    case trustAndSave, connectOnce, reject
}

/// Implemented by the app shell (sheet / takeover).
@MainActor public protocol HostKeyPrompter: AnyObject {
    /// For a mismatch the engine has already aborted; `.trustAndSave` means "reconnect with the new pin".
    func decide(_ challenge: HostKeyChallenge) async -> HostKeyDecision
}
