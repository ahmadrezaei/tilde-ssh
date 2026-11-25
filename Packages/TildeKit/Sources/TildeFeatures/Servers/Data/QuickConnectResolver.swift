import Foundation
import TildeCore

/// A key the resolver may pick for an ad-hoc connection.
struct QuickConnectKey: Equatable {
    var name: String
    /// The key's Keychain id (`SSHKeyRecord.privateSecretID`), which is what `ServerSnapshot.keyID` carries.
    var secretID: UUID
    var recordID: UUID
}

/// The outcome of resolving Quick Connect input.
struct QuickConnectResolution: Equatable {
    var server: ServerSnapshot
    /// `true` when an existing saved server matched (host + port + user).
    var isSaved: Bool
}

/// Auth resolution order from design section 4.4:
/// 1. A saved server matching host + port + user: use its settings.
/// 2. Otherwise the default key (Settings > Connections > Default key), or the key named by `-i`.
/// 3. Otherwise prompt for a password.
enum QuickConnectResolver {
    static func resolve(
        _ result: QuickConnectResult,
        saved: [ServerSnapshot],
        keys: [QuickConnectKey],
        defaultKeyRecordID: UUID?
    ) -> QuickConnectResolution {
        let target = result.target
        if let match = saved.first(where: { Self.matches($0.target, target) }) {
            return QuickConnectResolution(server: match, isSaved: true)
        }

        let key = result.keyName.flatMap { name in keys.first { $0.name == name } }
            ?? defaultKeyRecordID.flatMap { id in keys.first { $0.recordID == id } }

        let jump = result.jump.map { jumpTarget -> JumpSnapshot in
            // A saved server for the bastion carries its own auth; otherwise reuse the same key or prompt.
            if let match = saved.first(where: { Self.matches($0.target, jumpTarget) }) {
                return JumpSnapshot(target: match.target, auth: match.auth, keyID: match.keyID, passwordSecretID: match.passwordSecretID)
            }
            return JumpSnapshot(target: jumpTarget, auth: key == nil ? .passwordPrompt : .key, keyID: key?.secretID)
        }

        let server = ServerSnapshot(
            name: result.target.port == 22 ? result.target.host : result.target.hostPort,
            target: target,
            auth: key == nil ? .passwordPrompt : .key,
            keyID: key?.secretID,
            jump: jump
        )
        return QuickConnectResolution(server: server, isSaved: false)
    }

    /// The session for a connection requested by a `ssh://` link. A link is untrusted input, so it gets a password
    /// prompt only: no default key, no saved server's settings or startup command, no jump host, no key name.
    static func linkServer(_ result: QuickConnectResult) -> ServerSnapshot {
        ServerSnapshot(
            name: result.target.port == 22 ? result.target.host : result.target.hostPort,
            target: ConnectionTarget(host: result.target.host, port: result.target.port, username: result.target.username),
            auth: .passwordPrompt
        )
    }

    /// `user@host:port` as stored in `RecentConnection.target`.
    static func recentString(_ target: ConnectionTarget) -> String { target.displayString }

    private static func matches(_ a: ConnectionTarget, _ b: ConnectionTarget) -> Bool {
        a.host.caseInsensitiveCompare(b.host) == .orderedSame && a.port == b.port && a.username == b.username
    }
}
