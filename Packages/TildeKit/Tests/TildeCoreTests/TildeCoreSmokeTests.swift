import Foundation
import Testing
@testable import TildeCore

@Suite struct TildeCoreSmokeTests {
    @Test func moduleLoads() { #expect(TildeCoreModule.name == "TildeCore") }

    @Test func endpointCanonicalMatchesOpenSSH() {
        #expect(HostEndpoint(host: "Example.COM").canonical == "example.com")
        #expect(HostEndpoint(host: "Example.COM", port: 2222).canonical == "[example.com]:2222")
    }

    @Test func knownHostsLookupSemantics() async throws {
        let store = InMemoryKnownHostsStore()
        let endpoint = HostEndpoint(host: "10.0.2.5")
        let key = HostKey(algorithm: "ssh-ed25519", blobBase64: "AAAA", fingerprintSHA256: "SHA256:aaa")
        #expect(await store.lookup(endpoint, presented: key) == .unknown)
        try await store.trust(key, for: endpoint, replacing: false)
        #expect(await store.lookup(endpoint, presented: key) == .trusted)
        let other = HostKey(algorithm: "ssh-ed25519", blobBase64: "BBBB", fingerprintSHA256: "SHA256:bbb")
        guard case .mismatch(let pinned) = await store.lookup(endpoint, presented: other) else {
            Issue.record("expected a mismatch"); return
        }
        #expect(pinned.first?.key == key)
    }

    @Test func secretStoreRoundTrip() throws {
        let store = InMemorySecretStore()
        let ref = SecretRef(kind: .password, id: UUID())
        #expect(try store.read(ref) == nil)
        try store.write(Data("pw".utf8), for: ref, label: "Tilde: password", synchronizable: true)
        #expect(try store.read(ref) == Data("pw".utf8))
        #expect(try store.allRefs() == [ref])
        try store.delete(ref)
        #expect(try store.allRefs().isEmpty)
    }

    @Test func echoSessionConnectsAndEchoes() async throws {
        let session = EchoTerminalSession(server: PreviewServers.prodAPI, connectDelay: .milliseconds(1))
        await session.connect()
        var states = session.states.makeAsyncIterator()
        guard case .connected? = await states.next() else {
            Issue.record("expected the connected state to replay on subscribe"); return
        }
        var output = session.output.makeAsyncIterator()
        _ = await output.next()               // banner chunks
        session.send(Data("ls\r".utf8))
        var text = ""
        for _ in 0..<8 {
            guard let chunk = await output.next() else { break }
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains("deploy.sh") { break }
        }
        #expect(text.contains("deploy.sh"))
    }

    @Test func fakeEngineReturnsScriptedFailure() async {
        let engine = FakeSessionEngine(failure: .refused, connectDelay: .milliseconds(1))
        let request = SessionRequest(server: PreviewServers.devBox)
        let result = await engine.test(request, credentials: FakeCredentialResolver(), knownHosts: InMemoryKnownHostsStore(),
                                       hostKeyPrompter: await AlwaysTrustPrompter(), passwordPrompter: await FakePasswordPrompter())
        #expect(result == .failure(.refused))
    }

    @Test func snippetSeedsAreStable() async {
        let provider = StaticSnippetProvider()
        #expect(provider.all.count == 8)
        #expect(await provider.snippets(matching: "kubectl").count == 1)
    }
}
