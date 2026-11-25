import Foundation

// MARK: - Sessions (CitadelSessionEngine; mocks: FakeSessionEngine / EchoTerminalSession)

public struct PTYConfig: Sendable, Equatable {
    public var term: String
    public var cols: Int
    public var rows: Int
    public var env: [String: String]

    public init(term: String = "xterm-256color", cols: Int = 80, rows: Int = 24, env: [String: String] = [:]) {
        self.term = term
        self.cols = cols
        self.rows = rows
        self.env = env
    }
}

public struct SessionRequest: Sendable, Equatable {
    public var server: ServerSnapshot
    public var pty: PTYConfig
    public var connectTimeout: Duration

    public init(server: ServerSnapshot, pty: PTYConfig = PTYConfig(), connectTimeout: Duration = .seconds(15)) {
        self.server = server
        self.pty = pty
        self.connectTimeout = connectTimeout
    }
}

public struct ConnectionInfo: Equatable, Sendable {
    public var serverVersion: String
    public var kex: String
    public var cipher: String
    public var authenticatedWith: String
    public var latency: Duration?

    public init(serverVersion: String, kex: String, cipher: String, authenticatedWith: String, latency: Duration? = nil) {
        self.serverVersion = serverVersion
        self.kex = kex
        self.cipher = cipher
        self.authenticatedWith = authenticatedWith
        self.latency = latency
    }
}

public enum SessionState: Equatable, Sendable {
    case idle
    case connecting(phase: ConnectPhase)
    case connected(ConnectionInfo)
    case reconnecting(attempt: Int, retryAt: Date)
    case disconnected(SessionEndReason)
}

public enum ConnectPhase: Equatable, Sendable {
    case resolving, tcp, jumpHost, handshake, hostKey, authenticating, openingShell
}

public enum SessionEndReason: Equatable, Sendable {
    case exited(status: Int?)
    case userClosed
    case error(SessionError)
}

public enum SessionError: Error, Equatable, Sendable {
    case dnsFailure(host: String)
    case refused
    case timeout(seconds: Int)
    case networkLost
    case hostKeyMismatch(challengeID: UUID)
    case hostKeyRejected
    case authFailed(method: String, serverAllows: [String])
    case secretUnavailable(SecretRef)
    case noCommonAlgorithm(kind: String, offered: [String])
    case channelFailed(String)
    case underlying(String)
}

/// A live (or connecting) shell session.
public protocol TerminalSession: TerminalIO {
    var id: UUID { get }
    var server: ServerSnapshot { get }
    /// Replays the current state on subscribe.
    var states: AsyncStream<SessionState> { get }
    func connect() async
    func reconnect() async
    func disconnect() async
    /// Keep-alive round trip.
    func latency() async -> Duration?
}

public protocol SessionEngine: Sendable {
    func makeSession(
        _ request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore,
        hostKeyPrompter: any HostKeyPrompter,
        passwordPrompter: any PasswordPrompter
    ) -> any TerminalSession

    /// Handshake, host key and auth, then disconnect ("Test connection").
    func test(
        _ request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore,
        hostKeyPrompter: any HostKeyPrompter,
        passwordPrompter: any PasswordPrompter
    ) async -> Result<ConnectionInfo, SessionError>

    /// Runs one command over an exec channel (used by "Install key on server").
    func runCommand(
        _ command: String,
        on request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore
    ) async throws -> (stdout: Data, exitStatus: Int)
}
