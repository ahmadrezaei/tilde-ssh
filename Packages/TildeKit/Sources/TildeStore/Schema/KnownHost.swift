import Foundation
import SwiftData

/// A pinned host key (TOFU). Syncs to every device.
@Model
public final class KnownHost {
    public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    /// Canonical `host` (port 22) or `[host]:port`, same as OpenSSH `known_hosts`.
    public var endpoint: String = ""
    /// `ssh-ed25519` ...
    public var algorithm: String = ""
    /// Raw key blob, base64.
    public var publicKeyBase64: String = ""
    public var fingerprintSHA256: String = ""
    public var firstSeenAt: Date = Date.now
    /// Updated at most once a day to limit sync churn.
    public var lastSeenAt: Date = Date.now
    /// Device name.
    public var trustedOnDevice: String = ""
    /// `trusted` / `revoked` (the Deduplicator may also write `conflicted`).
    public var statusRaw: String = "trusted"
    /// Previous fingerprints + replacedAt, JSON.
    public var historyJSON: String?
    /// `tofu` / `imported` / `manual`.
    public var sourceRaw: String = "tofu"

    public init(
        endpoint: String = "",
        algorithm: String = "",
        publicKeyBase64: String = "",
        fingerprintSHA256: String = "",
        trustedOnDevice: String = "",
        sourceRaw: String = "tofu"
    ) {
        self.endpoint = endpoint
        self.algorithm = algorithm
        self.publicKeyBase64 = publicKeyBase64
        self.fingerprintSHA256 = fingerprintSHA256
        self.trustedOnDevice = trustedOnDevice
        self.sourceRaw = sourceRaw
    }
}
