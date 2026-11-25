import Foundation
import SwiftData

/// A saved connection. CloudKit-compatible: every property is optional or defaulted, no unique
/// constraints, relationships are optional with inverses. See docs/DESIGN.md section 6.1.
@Model
public final class Server {
    public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    /// Display name.
    public var name: String = ""
    /// Hostname / IP (stored trimmed, lowercased for matching).
    public var host: String = ""
    public var port: Int = 22
    public var username: String = ""
    /// `key` / `password` / `passwordPrompt`; see `AuthMethod`.
    public var authMethodRaw: String = "key"
    @Relationship(deleteRule: .nullify, inverse: \SSHKeyRecord.servers)
    public var key: SSHKeyRecord?
    /// References Keychain `pw:<uuid>`; nil when prompting.
    public var passwordSecretID: UUID?
    /// `none/dev/staging/prod/lab`; see `ServerEnvironment`.
    public var environmentRaw: String = "none"
    @Relationship(deleteRule: .nullify, inverse: \ServerGroup.servers)
    public var group: ServerGroup?
    @Relationship(deleteRule: .nullify, inverse: \Tag.servers)
    public var tags: [Tag]? = []
    /// ProxyJump (one hop at MVP).
    @Relationship(deleteRule: .nullify, inverse: \Server.jumpedBy)
    public var jumpServer: Server?
    /// Inverse of `jumpServer`.
    public var jumpedBy: [Server]? = []
    public var isFavorite: Bool = false
    /// Fractional ordering within a group.
    public var sortIndex: Double = 0
    public var startupCommand: String?
    public var autoTmux: Bool = false
    public var tmuxSessionName: String = "tilde"
    /// 0 = off.
    public var keepAliveSeconds: Int = 30
    public var termType: String = "xterm-256color"
    /// JSON object, e.g. `{"LANG":"en_US.UTF-8"}`.
    public var envVarsJSON: String?
    public var notes: String?
    /// Drives "recent" (syncs; writes are throttled).
    public var lastConnectedAt: Date?
    /// e.g. `ssh_config:Host prod-*`.
    public var importedFrom: String?
    /// Inverse of `Snippet.scopeServer` (CloudKit needs both sides; not in the §6.1 table).
    public var snippets: [Snippet]? = []
    /// Inverse of `RecentConnection.server` (CloudKit needs both sides; not in the §6.1 table).
    public var recents: [RecentConnection]? = []

    public init(
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethodRaw: String = "key",
        environmentRaw: String = "none"
    ) {
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethodRaw = authMethodRaw
        self.environmentRaw = environmentRaw
    }
}
