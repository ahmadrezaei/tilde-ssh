import Foundation
import Testing
@testable import TildeCore

/// Extra checks on the frozen contracts and the mocks the other modules build against.
@Suite struct ContractTests {
    @Test func endpointCanonicalFormHandlesIPv6AndCase() {
        #expect(HostEndpoint(host: "::1").canonical == "::1")
        #expect(HostEndpoint(host: "FE80::1", port: 2222).canonical == "[fe80::1]:2222")
        #expect(HostEndpoint(host: "a.example.com", port: 22) == HostEndpoint(host: "a.example.com"))
    }

    @Test func previewServersAreInternallyConsistent() {
        let all = PreviewServers.all
        #expect(Set(all.map(\.id)).count == all.count, "stable, unique ids")
        #expect(Set(all.map(\.name)).count == all.count)
        for server in all {
            if server.auth == .key { #expect(server.keyID == PreviewServers.keyID) }
            if server.auth == .password { #expect(server.passwordSecretID != nil) }
            if server.auth == .passwordPrompt { #expect(server.passwordSecretID == nil) }
        }
        #expect(PreviewServers.prodAPI.jump?.target == PreviewServers.bastion.target)
    }

    @Test func serverSnapshotDefaultsMatchTheSchemaDefaults() {
        let snapshot = ServerSnapshot(name: "x", target: ConnectionTarget(host: "h", username: "u"))
        #expect(snapshot.target.port == 22 && snapshot.auth == .key && snapshot.environment == .none)
        #expect(snapshot.keepAliveSeconds == 30 && snapshot.termType == "xterm-256color" && snapshot.tmuxSessionName == "tilde")
        #expect(snapshot.envVars.isEmpty && snapshot.jump == nil && !snapshot.autoTmux)
    }

    @Test func enumRawValuesAreStableBecauseTheyArePersisted() {
        #expect(ServerEnvironment.allCases.map(\.rawValue) == ["none", "dev", "staging", "prod", "lab"])
        #expect([AuthMethod.key, .password, .passwordPrompt].map(\.rawValue) == ["key", "password", "passwordPrompt"])
        #expect(SSHKeyAlgorithm.ed25519.rawValue == "ssh-ed25519" && SSHKeyAlgorithm.rsa.rawValue == "ssh-rsa")
        #expect(SecretKind.password.rawValue == "pw" && SecretKind.privateKey.rawValue == "key" && SecretKind.keyPassphrase.rawValue == "kpp")
    }

    @Test func mockKnownHostsReplaceDropsOldPins() async throws {
        let store = InMemoryKnownHostsStore()
        let endpoint = HostEndpoint(host: "h")
        let old = HostKey(algorithm: "ssh-ed25519", blobBase64: "AAAA", fingerprintSHA256: "SHA256:a")
        let new = HostKey(algorithm: "ssh-ed25519", blobBase64: "BBBB", fingerprintSHA256: "SHA256:b")
        try await store.trust(old, for: endpoint, replacing: false)
        try await store.trust(new, for: endpoint, replacing: true)
        #expect(await store.pinned(for: endpoint).map(\.key) == [new])
        await store.touch(endpoint)
        #expect(await store.touched == ["h"])
    }

    @Test func staticSnippetProviderFiltersByNameAndCommand() async {
        let provider = StaticSnippetProvider()
        #expect(await provider.snippets(matching: "").count == 8)
        #expect(await provider.snippets(matching: "SS -TULPN").map(\.name) == ["listening ports"])
        #expect(await provider.snippets(matching: "zzzz").isEmpty)
    }

    @Test func sessionStateEquality() {
        #expect(SessionState.idle == .idle)
        #expect(SessionState.connecting(phase: .tcp) != .connecting(phase: .handshake))
        #expect(SessionState.disconnected(.error(.refused)) == .disconnected(.error(.refused)))
    }
}
