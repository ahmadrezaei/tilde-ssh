import Foundation
import Testing
import TildeCore
@testable import TildeSSH

/// Key authentication against the one unprivileged sshd that `scripts/ci-sshd.sh` starts on CI runners
/// (`TILDE_SSH_INTEGRATION=1` plus `TILDE_TEST_SSH_*`). The Docker lab suites are skipped in that setup.
@Suite(.serialized, .enabled(if: Lab.isCIServerEnabled))
@MainActor
struct CIServerTests {
    private let engine = CitadelSessionEngine(options: .init(reconnect: .disabled))

    private func request(timeout: Duration = .seconds(10)) -> SessionRequest {
        SessionRequest(server: CIServer.server(), connectTimeout: timeout)
    }

    private func pinnedStore() async throws -> InMemoryKnownHostsStore {
        let store = InMemoryKnownHostsStore()
        try await store.trust(try CIServer.hostKey(), for: HostEndpoint(host: CIServer.host, port: CIServer.port), replacing: false)
        return store
    }

    @Test(arguments: [
        ("TILDE_TEST_SSH_KEY_ED25519", "ssh-ed25519"),
        ("TILDE_TEST_SSH_KEY_ECDSA", "ecdsa-sha2-nistp256"),
        ("TILDE_TEST_SSH_KEY_RSA", "rsa-sha2-512"),
    ])
    func keyAuthAgainstTheCIServer(variable: String, algorithm: String) async throws {
        let prompter = AlwaysTrustPrompter(decision: .connectOnce)
        let result = await engine.test(
            request(), credentials: CICredentials(variable: variable), knownHosts: InMemoryKnownHostsStore(),
            hostKeyPrompter: prompter, passwordPrompter: FakePasswordPrompter(response: nil)
        )
        guard case .success(let info) = result else { Issue.record("\(result)"); return }
        #expect(info.authenticatedWith == algorithm)
        // The presented host key is the one the script generated.
        #expect(prompter.challenges.first?.presented == (try CIServer.hostKey()))
    }

    @Test func pinnedHostRunsACommand() async throws {
        let store = try await pinnedStore()
        let result = try await engine.runCommand(
            "echo tilde-ci", on: request(), credentials: CICredentials(variable: "TILDE_TEST_SSH_KEY_ED25519"), knownHosts: store
        )
        #expect(String(decoding: result.stdout, as: UTF8.self) == "tilde-ci\n")
        #expect(result.exitStatus == 0)
    }

    @Test func shellSessionRoundTrip() async throws {
        let session = engine.makeSession(
            request(), credentials: CICredentials(variable: "TILDE_TEST_SSH_KEY_ED25519"), knownHosts: try await pinnedStore(),
            hostKeyPrompter: AlwaysTrustPrompter(), passwordPrompter: FakePasswordPrompter(response: nil)
        )
        let recorder = SessionRecorder(session)
        await session.connect()
        await recorder.settle()
        session.send(Data("echo $((20+22))\n".utf8))
        #expect(await recorder.waitForOutput("42"))
        await session.disconnect()
    }
}
