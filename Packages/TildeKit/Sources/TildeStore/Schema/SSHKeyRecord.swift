import Foundation
import SwiftData

/// Key metadata only. **No private material**: that lives in the Keychain under `key:<privateSecretID>`.
@Model
public final class SSHKeyRecord {
    public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    /// e.g. `macbook-ed25519`.
    public var name: String = ""
    /// `ssh-ed25519`, `ecdsa-sha2-nistp256/384/521`, `ssh-rsa`; see `SSHKeyAlgorithm`.
    public var algorithmRaw: String = "ssh-ed25519"
    /// RSA size.
    public var bits: Int?
    /// Full `ssh-ed25519 AAAA... comment` line (public, safe to sync).
    public var publicKeyOpenSSH: String = ""
    /// `SHA256:...`
    public var fingerprintSHA256: String = ""
    public var comment: String = ""
    /// `generated` / `imported` / `secureEnclave` (v1.1).
    public var sourceRaw: String = "generated"
    /// References Keychain `key:<uuid>`.
    public var privateSecretID: UUID = UUID()
    /// true = private key in iCloud Keychain; false = this device only.
    public var isSynchronizable: Bool = true
    /// For "this device only" keys, shown on other devices as "on MacBook Pro".
    public var originDeviceName: String = ""
    /// Inverse is declared on `Server.key`.
    public var servers: [Server]? = []

    public init(
        name: String = "",
        algorithmRaw: String = "ssh-ed25519",
        publicKeyOpenSSH: String = "",
        fingerprintSHA256: String = "",
        comment: String = "",
        privateSecretID: UUID = UUID()
    ) {
        self.name = name
        self.algorithmRaw = algorithmRaw
        self.publicKeyOpenSSH = publicKeyOpenSSH
        self.fingerprintSHA256 = fingerprintSHA256
        self.comment = comment
        self.privateSecretID = privateSecretID
    }
}
