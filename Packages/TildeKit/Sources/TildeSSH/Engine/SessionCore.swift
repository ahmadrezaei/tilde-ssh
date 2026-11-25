import Foundation
import Synchronization
import TildeCore

/// State shared between the session's synchronous entry points (`send`, `resize`) and its actor.
final class SessionShared: Sendable {
    struct Inner {
        var live: (any LiveShell)?
        var size: PTYConfig
        var pixelWidth = 0
        var pixelHeight = 0
        /// Incremented whenever a connect, reconnect or disconnect supersedes whatever was running.
        var epoch = 0
    }

    private let inner: Mutex<Inner>

    init(size: PTYConfig) { inner = Mutex(Inner(size: size)) }

    var live: (any LiveShell)? { inner.withLock { $0.live } }
    var size: PTYConfig { inner.withLock { $0.size } }
    var pixelSize: (width: Int, height: Int) { inner.withLock { ($0.pixelWidth, $0.pixelHeight) } }
    var epoch: Int { inner.withLock { $0.epoch } }

    func setLive(_ shell: (any LiveShell)?) { inner.withLock { $0.live = shell } }
    func setSize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        inner.withLock { $0.size.cols = cols; $0.size.rows = rows; $0.pixelWidth = pixelWidth; $0.pixelHeight = pixelHeight }
    }

    @discardableResult
    func advanceEpoch() -> Int { inner.withLock { $0.epoch += 1; return $0.epoch } }
}

/// The lifecycle of one session: connect, watch, keep alive, reconnect with backoff, disconnect.
///
/// All mutable state lives in this actor. Network work happens in the `ShellConnecting` implementation, so
/// the whole state machine is testable with a fake. `epoch` guards against stale work: every connect, reconnect
/// and disconnect advances it, and anything still running from an older epoch discards its result.
actor SessionCore {
    private enum Outcome {
        case connected
        case failed(SessionError)
        /// Superseded, cancelled by the user, or already reported (host key decision, prompt cancelled).
        case finished
    }

    private let makePlan: @Sendable (OnceAllowList) -> ConnectPlan
    private let connector: any ShellConnecting
    private let policy: ReconnectPolicy
    private let keepAliveInterval: Duration?
    private let keepAliveMissLimit: Int
    private let shared: SessionShared
    private let states: StateBroadcaster<SessionState>
    private let output: OutputPipe

    private var monitorTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private let allowedOnce = OnceAllowList()
    private var lastLatency: Duration?
    /// True while the UI is deciding about a changed host key; nothing else may start a connection meanwhile.
    private var decisionPending = false

    init(
        makePlan: @escaping @Sendable (OnceAllowList) -> ConnectPlan,
        connector: any ShellConnecting,
        policy: ReconnectPolicy,
        keepAliveInterval: Duration?,
        keepAliveMissLimit: Int,
        shared: SessionShared,
        states: StateBroadcaster<SessionState>,
        output: OutputPipe
    ) {
        self.makePlan = makePlan
        self.connector = connector
        self.policy = policy
        self.keepAliveInterval = keepAliveInterval
        self.keepAliveMissLimit = keepAliveMissLimit
        self.shared = shared
        self.states = states
        self.output = output
    }

    // MARK: Public operations

    func connect() async {
        switch states.current {
        case .connecting, .connected, .reconnecting: return
        case .idle, .disconnected: break
        }
        guard !decisionPending else { return }
        let epoch = shared.advanceEpoch()
        await runFirstAttempt(epoch: epoch, announceReconnect: false)
    }

    /// Drops the current connection (if any) and connects again right away. A failure is reported, not retried.
    func reconnect() async {
        guard !decisionPending else { return }
        let epoch = shared.advanceEpoch()
        await tearDown()
        await runFirstAttempt(epoch: epoch, announceReconnect: true)
    }

    func disconnect() async {
        shared.advanceEpoch()
        await tearDown()
        states.send(.disconnected(.userClosed))
    }

    func latency() async -> Duration? {
        guard let shell = shared.live else { return nil }
        let rtt = await shell.ping(timeout: .seconds(5))
        if let rtt { lastLatency = rtt }
        return rtt
    }

    // MARK: Connecting

    private func runFirstAttempt(epoch: Int, announceReconnect: Bool) async {
        switch await attempt(epoch: epoch, announceReconnect: announceReconnect) {
        case .connected, .finished: break
        case .failed(let error): if shared.epoch == epoch { states.send(.disconnected(.error(error))) }
        }
    }

    private func attempt(epoch: Int, announceReconnect: Bool, afterHostKeyDecision: Bool = false) async -> Outcome {
        guard shared.epoch == epoch else { return .finished }
        states.send(.connecting(phase: .resolving))

        let plan = makePlan(allowedOnce)
        let host = plan.request.server.target.host
        let timeoutSeconds = plan.request.connectTimeout.wholeSecondsRoundedUp
        let events = ConnectEvents(
            phase: { [shared, states] phase in
                if shared.epoch == epoch { states.send(.connecting(phase: phase)) }
            },
            output: { [output] data in output.push(data) }
        )

        do {
            let usedSize = shared.size
            let shell = try await connector.connect(plan, size: usedSize, events: events)
            guard shared.epoch == epoch else {
                await shell.close()
                return .finished
            }
            shared.setLive(shell)
            output.setReadControl { shell.setReading($0) }
            // A resize that arrived while connecting only updated the stored size; the PTY was opened with the old one.
            let latest = shared.size
            if latest.cols != usedSize.cols || latest.rows != usedSize.rows {
                shell.resize(cols: latest.cols, rows: latest.rows, pixelWidth: shared.pixelSize.width, pixelHeight: shared.pixelSize.height)
            }
            states.send(.connected(shell.info))
            if announceReconnect { output.push(Data("\r\n\u{1B}[2m[Tilde] Reconnected\u{1B}[0m\r\n".utf8)) }
            startWatching(shell, epoch: epoch)
            return .connected
        } catch let mismatch as HostKeyMismatchError {
            guard shared.epoch == epoch else { return .finished }
            return await handleMismatch(mismatch.challenge, plan: plan, epoch: epoch, announceReconnect: announceReconnect, alreadyRetried: afterHostKeyDecision)
        } catch is ConnectCancelledError {
            if shared.epoch == epoch { states.send(.disconnected(.userClosed)) }
            return .finished
        } catch {
            guard shared.epoch == epoch else { return .finished }
            return .failed(SessionErrorMapper.map(error, host: host, timeoutSeconds: timeoutSeconds))
        }
    }

    /// The pinned key changed. The connection was already aborted before any credential was sent; publish
    /// that, hand the challenge to the UI, and reconnect with the new pin if the user decides to trust it.
    private func handleMismatch(
        _ challenge: HostKeyChallenge, plan: ConnectPlan, epoch: Int, announceReconnect: Bool, alreadyRetried: Bool
    ) async -> Outcome {
        states.send(.disconnected(.error(.hostKeyMismatch(challengeID: challenge.id))))
        guard !alreadyRetried, let prompter = plan.hostKeyPrompter else { return .finished }

        decisionPending = true
        let decision = await prompter.decide(challenge)
        decisionPending = false
        guard shared.epoch == epoch else { return .finished }
        switch decision {
        case .trustAndSave:
            do {
                try await plan.knownHosts.trust(challenge.presented, for: challenge.endpoint, replacing: true)
            } catch {
                return .failed(.underlying("The new host key could not be saved."))
            }
        case .connectOnce:
            allowedOnce.insert(challenge.presented, for: challenge.endpoint)
        case .reject:
            return .finished
        }
        return await attempt(epoch: epoch, announceReconnect: announceReconnect, afterHostKeyDecision: true)
    }

    // MARK: Watching a live shell

    private func startWatching(_ shell: any LiveShell, epoch: Int) {
        monitorTask?.cancel()
        keepAliveTask?.cancel()

        if let interval = keepAliveInterval {
            let missLimit = keepAliveMissLimit
            keepAliveTask = Task { [weak self] in
                var misses = 0
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    if let rtt = await shell.ping(timeout: interval) {
                        misses = 0
                        await self?.record(latency: rtt)
                    } else {
                        misses += 1
                        if misses >= missLimit {
                            await shell.drop()
                            return
                        }
                    }
                }
            }
        }

        monitorTask = Task { [weak self] in
            let end = await shell.waitUntilEnded()
            await self?.shellEnded(end, epoch: epoch)
        }
    }

    private func record(latency: Duration) { lastLatency = latency }

    private func shellEnded(_ end: ShellEnd, epoch: Int) async {
        guard shared.epoch == epoch else { return }
        keepAliveTask?.cancel()
        shared.setLive(nil)
        output.setReadControl(nil)

        switch end {
        case .closedLocally:
            return
        case .exited(let status):
            states.send(.disconnected(.exited(status: status)))
        case .lost:
            guard policy.isEnabled else {
                states.send(.disconnected(.error(.networkLost)))
                return
            }
            await reconnectLoop(epoch: epoch)
        }
    }

    /// Exponential backoff after an unexpected drop.
    private func reconnectLoop(epoch: Int) async {
        var lastError: SessionError = .networkLost
        var attemptNumber = 1
        while attemptNumber <= policy.maxAttempts {
            guard shared.epoch == epoch, !Task.isCancelled else { return }

            let delay = policy.delay(forAttempt: attemptNumber)
            let seconds = delay.totalSeconds
            states.send(.reconnecting(attempt: attemptNumber, retryAt: Date().addingTimeInterval(seconds)))
            do { try await Task.sleep(for: delay) } catch { return }
            guard shared.epoch == epoch else { return }

            switch await attempt(epoch: epoch, announceReconnect: true) {
            case .connected, .finished:
                return
            case .failed(let error):
                if SessionErrorMapper.isRetriable(error) {
                    lastError = error
                    attemptNumber += 1
                } else {
                    states.send(.disconnected(.error(error)))
                    return
                }
            }
        }
        if shared.epoch == epoch { states.send(.disconnected(.error(lastError))) }
    }

    private func tearDown() async {
        monitorTask?.cancel()
        keepAliveTask?.cancel()
        monitorTask = nil
        keepAliveTask = nil
        let shell = shared.live
        shared.setLive(nil)
        output.setReadControl(nil)
        await shell?.close()
    }
}
