import Foundation
import TildeCore

/// A live SSH shell session.
///
/// This type is a thin, Sendable facade: keyboard input and resizes go straight to the connection (they are
/// ordered and never block), while connecting, keep-alive and reconnect run inside an internal actor.
///
/// - `output` is created once and keeps delivering bytes across reconnects.
/// - `states` replays the current state to each new subscriber.
public final class CitadelTerminalSession: TerminalSession {
    public let id: UUID
    public let server: ServerSnapshot

    private let outputPipe = OutputPipe()
    private let stateBroadcaster = StateBroadcaster<SessionState>(initial: .idle)
    private let shared: SessionShared
    private let core: SessionCore

    init(
        id: UUID = UUID(),
        request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore,
        hostKeyPrompter: any HostKeyPrompter,
        passwordPrompter: any PasswordPrompter,
        options: CitadelSessionEngine.Options,
        connector: any ShellConnecting
    ) {
        self.id = id
        self.server = request.server

        let shared = SessionShared(size: request.pty)
        self.shared = shared

        let hostAsker = HostKeyAsker(hostKeyPrompter)
        let passwordAsker = PasswordAsker(passwordPrompter)
        let makePlan: @Sendable (OnceAllowList) -> ConnectPlan = { allowedOnce in
            ConnectPlan(
                request: request,
                credentials: credentials,
                knownHosts: knownHosts,
                hostKeyPrompter: hostAsker,
                passwordPrompter: passwordAsker,
                options: options,
                allowedOnce: allowedOnce
            )
        }
        let keepAlive: Duration? = request.server.keepAliveSeconds > 0 ? .seconds(request.server.keepAliveSeconds) : nil
        self.core = SessionCore(
            makePlan: makePlan,
            connector: connector,
            policy: options.reconnect,
            keepAliveInterval: keepAlive,
            keepAliveMissLimit: options.keepAliveMissLimit,
            shared: shared,
            states: stateBroadcaster,
            output: outputPipe
        )
    }

    deinit {
        outputPipe.finish()
        let core = core
        Task { await core.disconnect() }
    }

    // MARK: TerminalSession

    public var states: AsyncStream<SessionState> { stateBroadcaster.stream() }

    public func connect() async { await core.connect() }

    public func reconnect() async { await core.reconnect() }

    public func disconnect() async { await core.disconnect() }

    /// Sends a keep-alive request and returns the round-trip time, or `nil` if not connected or unanswered.
    public func latency() async -> Duration? { await core.latency() }

    // MARK: TerminalIO

    /// Remote bytes. Each access returns a fresh stream over the same queue, so a view that is recreated can
    /// simply subscribe again. Reading from the network pauses while more than 4 MiB are unconsumed.
    public var output: AsyncStream<Data> {
        let pipe = outputPipe
        return AsyncStream(unfolding: { await pipe.next() })
    }

    /// Bytes received but not yet consumed by `output` (exposed for tests).
    var pendingOutputBytes: Int { outputPipe.pendingBytes }

    /// Queues keyboard bytes. Input typed while not connected is dropped.
    public func send(_ bytes: Data) {
        shared.live?.write(bytes)
    }

    public func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        shared.setSize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        shared.live?.resize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
}
