import Foundation
import SwiftData
import TildeCore

// MARK: - Model -> snapshot

public extension ServerSnapshot {
    /// Maps a stored server to the Sendable snapshot handed to the SSH engine and UI.
    ///
    /// `keyID` is the key's `privateSecretID` (the id of its `key:<uuid>` Keychain item), which is what the
    /// credential resolver reads; it is not `SSHKeyRecord.id`.
    ///
    /// Call on the actor that owns the model's `ModelContext`. Unknown raw values fall back to the defaults
    /// (`key` auth, no environment), so a record written by a newer app version never crashes an older one.
    init(model: Server) {
        self.init(
            id: model.id,
            name: model.name,
            target: model.connectionTarget,
            auth: model.authMethod,
            keyID: model.key?.privateSecretID,
            passwordSecretID: model.passwordSecretID,
            environment: model.environment,
            jump: model.jumpServer.map { JumpSnapshot(model: $0) },
            startupCommand: model.startupCommand?.nilIfBlank,
            autoTmux: model.autoTmux,
            tmuxSessionName: model.tmuxSessionName,
            keepAliveSeconds: model.keepAliveSeconds,
            termType: model.termType,
            envVars: model.envVars
        )
    }
}

public extension JumpSnapshot {
    /// Maps the bastion server to a jump snapshot (target and credentials only).
    init(model: Server) {
        self.init(
            target: model.connectionTarget,
            auth: model.authMethod,
            keyID: model.key?.privateSecretID,
            passwordSecretID: model.passwordSecretID
        )
    }
}

public extension SnippetSnapshot {
    /// Maps a stored snippet to its Sendable snapshot.
    init(model: Snippet) {
        self.init(id: model.id, name: model.name, command: model.command, runOnInsert: model.runMode == .insertAndReturn)
    }
}

// MARK: - Snapshot / Quick Connect -> model

public extension Server {
    /// A new, unsaved server from a snapshot. Relationships are not set; use `apply(_:in:)` after inserting
    /// the server to resolve the key and jump host.
    convenience init(snapshot: ServerSnapshot) {
        self.init()
        self.id = snapshot.id
        copyFields(from: snapshot)
    }

    /// A new, unsaved server from a Quick Connect result ("Save as server..."). The name defaults to the host.
    /// The key (`keyName`) and jump host are resolved by `ServerRepository.createServer(from:)`.
    convenience init(quickConnect result: QuickConnectResult, name: String? = nil, auth: AuthMethod = .key, passwordSecretID: UUID? = nil) {
        self.init()
        let host = Server.normalizedHost(result.target.host)
        self.name = name?.nilIfBlank ?? host
        self.host = host
        self.port = result.target.port
        self.username = result.target.username
        self.authMethod = auth
        self.passwordSecretID = auth == .password ? passwordSecretID : nil
    }

    /// Copies every field of `snapshot` onto this server and resolves the key (by `keyID`, a `privateSecretID`) and jump host (by
    /// matching host, port and user among `context`'s servers). A snapshot without a key or jump host clears
    /// the relationship; one that names a key or jump host missing from the store leaves it unchanged, so a
    /// record that has not synced yet never erases a good link.
    ///
    /// The snapshot's `id` is not applied (a server keeps its identity).
    func apply(_ snapshot: ServerSnapshot, in context: ModelContext) throws {
        copyFields(from: snapshot)
        if let keyID = snapshot.keyID {
            var descriptor = FetchDescriptor<SSHKeyRecord>(predicate: #Predicate { $0.privateSecretID == keyID })
            descriptor.fetchLimit = 1
            if let found = try context.fetch(descriptor).first { key = found }
        } else {
            key = nil
        }
        if let jump = snapshot.jump {
            let host = Server.normalizedHost(jump.target.host), port = jump.target.port, user = jump.target.username
            let selfID = id
            let descriptor = FetchDescriptor<Server>(predicate: #Predicate {
                $0.host == host && $0.port == port && $0.username == user && $0.id != selfID
            })
            if let found = try context.fetch(descriptor).first { jumpServer = found }
        } else {
            jumpServer = nil
        }
        updatedAt = .now
    }

    /// The plain (non-relationship) fields.
    private func copyFields(from snapshot: ServerSnapshot) {
        name = snapshot.name
        host = Server.normalizedHost(snapshot.target.host)
        port = snapshot.target.port
        username = snapshot.target.username
        authMethod = snapshot.auth
        passwordSecretID = snapshot.passwordSecretID
        environment = snapshot.environment
        startupCommand = snapshot.startupCommand
        autoTmux = snapshot.autoTmux
        tmuxSessionName = snapshot.tmuxSessionName
        keepAliveSeconds = snapshot.keepAliveSeconds
        termType = snapshot.termType
        envVars = snapshot.envVars
    }
}

extension String {
    /// `nil` when empty or whitespace only.
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
