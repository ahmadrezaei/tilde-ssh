import Foundation

/// A `SessionEngine` that hands out `EchoTerminalSession`s. Set `failure` to make every session
/// (and `test`) fail with a scripted error, which is handy for banner/error-state previews.
public struct FakeSessionEngine: SessionEngine {
    public var failure: SessionError?
    public var connectDelay: Duration

    public init(failure: SessionError? = nil, connectDelay: Duration = .milliseconds(300)) {
        self.failure = failure
        self.connectDelay = connectDelay
    }

    public func makeSession(
        _ request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore,
        hostKeyPrompter: any HostKeyPrompter,
        passwordPrompter: any PasswordPrompter
    ) -> any TerminalSession {
        EchoTerminalSession(server: request.server, connectDelay: connectDelay, failure: failure)
    }

    public func test(
        _ request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore,
        hostKeyPrompter: any HostKeyPrompter,
        passwordPrompter: any PasswordPrompter
    ) async -> Result<ConnectionInfo, SessionError> {
        try? await Task.sleep(for: connectDelay)
        if let failure { return .failure(failure) }
        return .success(ConnectionInfo(
            serverVersion: "SSH-2.0-OpenSSH_9.6", kex: "curve25519-sha256",
            cipher: "aes256-gcm@openssh.com", authenticatedWith: "ssh-ed25519",
            latency: .milliseconds(182)
        ))
    }

    public func runCommand(
        _ command: String,
        on request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore
    ) async throws -> (stdout: Data, exitStatus: Int) {
        if let failure { throw failure }
        return (Data("ok\n".utf8), 0)
    }
}
