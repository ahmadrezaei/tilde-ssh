import Foundation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

@MainActor
@Suite struct MapperTests {
    @Test func serverMapsToSnapshot() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let key = SSHKeyRecord(name: "k", privateSecretID: UUID())
        let bastion = Server(name: "bastion", host: "b.example.com", username: "ops")
        bastion.key = key
        let server = Server(name: "db", host: "10.0.0.5", port: 2222, username: "postgres", authMethodRaw: "key", environmentRaw: "prod")
        server.key = key
        server.jumpServer = bastion
        server.startupCommand = "tmux new -A -s db"
        server.autoTmux = true
        server.tmuxSessionName = "db"
        server.keepAliveSeconds = 15
        server.termType = "xterm"
        server.envVars = ["LANG": "en_US.UTF-8"]
        [key].forEach(context.insert)
        context.insert(bastion); context.insert(server)

        let snapshot = ServerSnapshot(model: server)
        #expect(snapshot.id == server.id)
        #expect(snapshot.name == "db")
        #expect(snapshot.target == ConnectionTarget(host: "10.0.0.5", port: 2222, username: "postgres"))
        #expect(snapshot.auth == .key)
        #expect(snapshot.keyID == key.privateSecretID)
        #expect(snapshot.environment == .prod)
        #expect(snapshot.jump == JumpSnapshot(target: ConnectionTarget(host: "b.example.com", username: "ops"), auth: .key, keyID: key.privateSecretID))
        #expect(snapshot.startupCommand == "tmux new -A -s db")
        #expect(snapshot.autoTmux && snapshot.tmuxSessionName == "db")
        #expect(snapshot.keepAliveSeconds == 15 && snapshot.termType == "xterm")
        #expect(snapshot.envVars == ["LANG": "en_US.UTF-8"])
    }

    @Test func unknownRawValuesFallBackToDefaults() {
        let server = Server(name: "x", host: "h", username: "u", authMethodRaw: "kerberos-from-the-future", environmentRaw: "qa")
        server.envVarsJSON = "not json"
        server.startupCommand = "   "
        let snapshot = ServerSnapshot(model: server)
        #expect(snapshot.auth == .key)
        #expect(snapshot.environment == .none)
        #expect(snapshot.envVars.isEmpty)
        #expect(snapshot.startupCommand == nil)
    }

    @Test func passwordSecretIDIsCarriedButNeverTheSecret() {
        let id = UUID()
        let server = Server(name: "x", host: "h", username: "u", authMethodRaw: "password")
        server.passwordSecretID = id
        let snapshot = ServerSnapshot(model: server)
        #expect(snapshot.auth == .password)
        #expect(snapshot.passwordSecretID == id)
    }

    @Test func snapshotCreatesAServerAndRoundTrips() throws {
        let container = try makeContainer()
        let repo = ServerRepository(context: container.mainContext)
        let original = PreviewServers.stagingWeb
        let server = try repo.createServer(from: original)
        #expect(server.id == original.id)
        #expect(ServerSnapshot(model: server) == original)
    }

    @Test func applyResolvesKeyAndJumpHostFromTheStore() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let key = SSHKeyRecord(name: "k", publicKeyOpenSSH: "ssh-ed25519 AAAA", privateSecretID: UUID())
        let bastion = Server(name: "bastion", host: "bastion.example.com", username: "ops")
        context.insert(key); context.insert(bastion)

        let server = Server(name: "old", host: "old", username: "old")
        context.insert(server)
        let snapshot = ServerSnapshot(
            id: UUID(), name: "new", target: ConnectionTarget(host: "NEW.Example.com", port: 2200, username: "deploy"),
            auth: .key, keyID: key.privateSecretID, environment: .staging,
            jump: JumpSnapshot(target: ConnectionTarget(host: "Bastion.example.com", username: "ops"))
        )
        try server.apply(snapshot, in: context)
        #expect(server.name == "new" && server.host == "new.example.com" && server.port == 2200)
        #expect(server.environment == .staging)
        #expect(server.key?.id == key.id)
        #expect(server.jumpServer?.id == bastion.id)
        #expect(server.id != snapshot.id, "applying a snapshot never changes the server's identity")

        let cleared = ServerSnapshot(name: "new", target: server.connectionTarget, auth: .passwordPrompt)
        try server.apply(cleared, in: context)
        #expect(server.key == nil && server.jumpServer == nil)
    }

    @Test func applyKeepsLinksWhenTheKeyHasNotSyncedYet() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let key = SSHKeyRecord(name: "k", privateSecretID: UUID())
        let server = Server(name: "s", host: "h", username: "u")
        server.key = key
        context.insert(key); context.insert(server)
        let snapshot = ServerSnapshot(name: "s", target: server.connectionTarget, auth: .key, keyID: UUID())
        try server.apply(snapshot, in: context)
        #expect(server.key?.id == key.id)
    }

    @Test func quickConnectResultBecomesAServer() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let key = SSHKeyRecord(name: "macbook-ed25519", publicKeyOpenSSH: "ssh-ed25519 AAAA", privateSecretID: UUID())
        let bastion = Server(name: "bastion", host: "bastion.example.com", username: "ops")
        context.insert(key); context.insert(bastion)

        let result = QuickConnectResult(
            target: ConnectionTarget(host: "10.0.4.12", port: 2222, username: "deploy"),
            keyName: "macbook-ed25519",
            jump: ConnectionTarget(host: "bastion.example.com", username: "ops")
        )
        let repo = ServerRepository(context: context)
        let server = try repo.createServer(from: result)
        #expect(server.name == "10.0.4.12", "the name defaults to the host")
        #expect(server.connectionTarget == result.target)
        #expect(server.key?.id == key.id)
        #expect(server.jumpServer?.id == bastion.id)

        let named = try repo.createServer(from: QuickConnectResult(target: ConnectionTarget(host: "a.example.com", username: "u")), name: "alpha", auth: .passwordPrompt)
        #expect(named.name == "alpha" && named.authMethod == .passwordPrompt && named.passwordSecretID == nil)
    }

    @Test func snippetMapsRunMode() {
        let snippet = Snippet(name: "n", command: "c", runModeRaw: SnippetRunMode.insertAndReturn.rawValue)
        #expect(SnippetSnapshot(model: snippet).runOnInsert)
        snippet.runMode = .insert
        #expect(!SnippetSnapshot(model: snippet).runOnInsert)
        snippet.runModeRaw = "something-new"
        #expect(snippet.runMode == .insert)
    }
}
