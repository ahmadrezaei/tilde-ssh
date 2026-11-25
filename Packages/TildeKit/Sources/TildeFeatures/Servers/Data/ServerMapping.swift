import Foundation
import TildeCore
import TildeStore

/// Maps SwiftData `Server` rows to the Sendable `ServerSnapshot` the engine consumes.
///
/// Interim: WS1 ships `ServerSnapshot(model:)` in `TildeStore/Seeding`. When it lands, delete this file and call
/// that mapper from `ServerMapper.snapshot(_:)`'s call sites. Conventions (shared with `PreviewSeed`):
/// `ServerSnapshot.keyID` is the key's `privateSecretID` (the Keychain `key:<uuid>` item), not `SSHKeyRecord.id`.
enum ServerMapper {
    static func snapshot(_ server: Server) -> ServerSnapshot {
        ServerSnapshot(
            id: server.id,
            name: displayName(server),
            target: target(server),
            auth: AuthMethod(rawValue: server.authMethodRaw) ?? .key,
            keyID: server.key?.privateSecretID,
            passwordSecretID: server.passwordSecretID,
            environment: ServerEnvironment(rawValue: server.environmentRaw) ?? .none,
            jump: server.jumpServer.map(jump),
            startupCommand: nonEmpty(server.startupCommand),
            autoTmux: server.autoTmux,
            tmuxSessionName: server.tmuxSessionName.isEmpty ? "tilde" : server.tmuxSessionName,
            keepAliveSeconds: server.keepAliveSeconds,
            termType: server.termType.isEmpty ? "xterm-256color" : server.termType,
            envVars: envVars(json: server.envVarsJSON)
        )
    }

    static func target(_ server: Server) -> ConnectionTarget {
        ConnectionTarget(host: server.host, port: server.port, username: server.username)
    }

    static func jump(_ server: Server) -> JumpSnapshot {
        JumpSnapshot(
            target: target(server),
            auth: AuthMethod(rawValue: server.authMethodRaw) ?? .key,
            keyID: server.key?.privateSecretID,
            passwordSecretID: server.passwordSecretID
        )
    }

    static func displayName(_ server: Server) -> String {
        server.name.isEmpty ? server.host : server.name
    }

    static func environment(_ server: Server) -> ServerEnvironment {
        ServerEnvironment(rawValue: server.environmentRaw) ?? .none
    }

    static func authMethod(_ server: Server) -> AuthMethod {
        AuthMethod(rawValue: server.authMethodRaw) ?? .key
    }

    static func envVars(json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return object
    }

    static func envVarsJSON(_ vars: [String: String]) -> String? {
        guard !vars.isEmpty, let data = try? JSONEncoder().encode(vars) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// `deploy@10.0.1.12:2222`, omitting the port when it is 22.
extension ConnectionTarget {
    var displayString: String { port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)" }
    var hostPort: String { "\(host):\(port)" }
}
