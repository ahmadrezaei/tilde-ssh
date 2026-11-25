import Foundation
import Synchronization
import Testing
import TildeCore
@testable import TildeSSH

// MARK: - Fakes

final class FakeShell: LiveShell {
    let info = ConnectionInfo(serverVersion: "SSH-2.0-Fake", kex: "curve25519-sha256", cipher: "aes256-gcm@openssh.com", authenticatedWith: "password")
    private let endStream: AsyncStream<ShellEnd>
    private let endContinuation: AsyncStream<ShellEnd>.Continuation
    private let log = Mutex(Log())

    struct Log {
        var written: [Data] = []
        var resizes: [[Int]] = []
        var pingResult: Duration? = .milliseconds(12)
        var closed = false
        var pings = 0
    }

    init() { (endStream, endContinuation) = AsyncStream.makeStream() }

    var written: [Data] { log.withLock { $0.written } }
    var resizes: [[Int]] { log.withLock { $0.resizes } }
    var wasClosed: Bool { log.withLock { $0.closed } }
    var pings: Int { log.withLock { $0.pings } }
    func setPing(_ value: Duration?) { log.withLock { $0.pingResult = value } }

    func write(_ data: Data) { log.withLock { $0.written.append(data) } }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) { log.withLock { $0.resizes.append([cols, rows, pixelWidth, pixelHeight]) } }
    func setReading(_ enabled: Bool) {}
    func ping(timeout: Duration) async -> Duration? { log.withLock { $0.pings += 1; return $0.pingResult } }

    func waitUntilEnded() async -> ShellEnd {
        for await end in endStream { return end }
        return .lost
    }

    /// Simulates the remote side ending the session.
    func end(_ end: ShellEnd) { endContinuation.yield(end); endContinuation.finish() }
    func close() async { log.withLock { $0.closed = true }; end(.closedLocally) }
    func drop() async { end(.lost) }
}

final class FakeConnector: ShellConnecting {
    enum Step { case shell(FakeShell), fail(any Error) }

    private let steps: Mutex<[Step]>
    private let count = Mutex(0)
    private let delay: Duration
    private let lists = Mutex<[OnceAllowList]>([])
    private let sizes = Mutex<[PTYConfig]>([])

    init(_ steps: [Step], delay: Duration = .zero) { self.steps = Mutex(steps); self.delay = delay }

    /// The `OnceAllowList` each attempt was given (they must all be the same object).
    var allowLists: [OnceAllowList] { lists.withLock { $0 } }
    var sizesUsed: [PTYConfig] { sizes.withLock { $0 } }

    var connectCount: Int { count.withLock { $0 } }

    func connect(_ plan: ConnectPlan, size: PTYConfig, events: ConnectEvents) async throws -> any LiveShell {
        count.withLock { $0 += 1 }
        lists.withLock { $0.append(plan.allowedOnce) }
        sizes.withLock { $0.append(size) }
        events.phase(.tcp)
        events.phase(.authenticating)
        if delay > .zero { try await Task.sleep(for: delay) }
        let step = steps.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        switch step {
        case .shell(let shell)?: return shell
        case .fail(let error)?: throw error
        case nil: throw SessionError.refused
        }
    }
}

// MARK: - Tests

private func isReconnecting(_ state: SessionState) -> Bool { if case .reconnecting = state { true } else { false } }
private func isConnected(_ state: SessionState) -> Bool { if case .connected = state { true } else { false } }

@Suite @MainActor
struct SessionCoreTests {
    private let fastPolicy = ReconnectPolicy(maxAttempts: 4, schedule: [.milliseconds(20), .milliseconds(40)])

    private func makeSession(
        _ connector: FakeConnector, policy: ReconnectPolicy? = nil, keepAlive: Int = 0, knownHosts: InMemoryKnownHostsStore = InMemoryKnownHostsStore(),
        hostKey: any HostKeyPrompter = AlwaysTrustPrompter()
    ) -> (CitadelTerminalSession, SessionRecorder) {
        let server = ServerSnapshot(name: "fake", target: ConnectionTarget(host: "fake.test", username: "me"), keepAliveSeconds: keepAlive)
        let session = CitadelTerminalSession(
            request: SessionRequest(server: server), credentials: FakeCredentialResolver(), knownHosts: knownHosts,
            hostKeyPrompter: hostKey, passwordPrompter: FakePasswordPrompter(),
            options: .init(reconnect: policy ?? fastPolicy, keepAliveMissLimit: 2), connector: connector
        )
        return (session, SessionRecorder(session))
    }

    @Test func statesReplayAndConnectSequence() async {
        let shell = FakeShell()
        let (session, recorder) = makeSession(FakeConnector([.shell(shell)]))
        // A late subscriber sees the current state first.
        var iterator = session.states.makeAsyncIterator()
        #expect(await iterator.next() == .idle)

        await session.connect()
        await recorder.settle()
        let states = recorder.allStates
        #expect(states.first == .idle)
        #expect(states.contains(.connecting(phase: .resolving)))
        #expect(states.contains(.connecting(phase: .tcp)))
        #expect(states.contains(.connecting(phase: .authenticating)))
        guard case .connected(let info)? = states.last else { Issue.record("last state \(String(describing: states.last))"); return }
        #expect(info.serverVersion == "SSH-2.0-Fake")

        var late = session.states.makeAsyncIterator()
        if case .connected? = await late.next() {} else { Issue.record("late subscriber did not get the replayed state") }
    }

    @Test func inputAndResizeReachTheShellInOrder() async {
        let shell = FakeShell()
        let (session, recorder) = makeSession(FakeConnector([.shell(shell)]))
        session.send(Data("dropped".utf8))   // not connected yet
        await session.connect()
        await recorder.settle()
        for text in ["a", "b", "c"] { session.send(Data(text.utf8)) }
        session.resize(cols: 120, rows: 40, pixelWidth: 1, pixelHeight: 2)
        #expect(shell.written.map { String(decoding: $0, as: UTF8.self) } == ["a", "b", "c"])
        #expect(shell.resizes == [[120, 40, 1, 2]])
    }

    @Test func initialFailureIsReportedWithoutRetrying() async {
        let connector = FakeConnector([.fail(SessionError.refused), .shell(FakeShell())])
        let (session, recorder) = makeSession(connector)
        await session.connect()
        await recorder.settle()
        #expect(recorder.lastState == .disconnected(.error(.refused)))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(connector.connectCount == 1)
    }

    @Test func shellExitDoesNotReconnect() async {
        let shell = FakeShell()
        let connector = FakeConnector([.shell(shell), .shell(FakeShell())])
        let (session, recorder) = makeSession(connector)
        await session.connect()
        shell.end(.exited(status: 5))
        #expect(await recorder.waitForState { $0 == .disconnected(.exited(status: 5)) })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(connector.connectCount == 1)
    }

    @Test func lostConnectionReconnectsWithBackoff() async {
        let first = FakeShell(), second = FakeShell()
        // After the drop: two refused attempts, then success.
        let connector = FakeConnector([.shell(first), .fail(SessionError.refused), .fail(SessionError.timeout(seconds: 1)), .shell(second)])
        let (session, recorder) = makeSession(connector, policy: ReconnectPolicy(maxAttempts: 5, schedule: [.milliseconds(30), .milliseconds(60)]))
        await session.connect()
        await recorder.settle()

        first.end(.lost)
        #expect(await recorder.waitForState { _ in recorder.allStates.filter(isReconnecting).count >= 3 && recorder.lastState.map(isConnected) == true })

        let attempts = recorder.allStates.compactMap { state -> Int? in
            if case .reconnecting(let attempt, _) = state { attempt } else { nil }
        }
        #expect(attempts == [1, 2, 3])
        // retryAt advertises the scheduled wait.
        for state in recorder.allStates {
            if case .reconnecting(let attempt, let retryAt) = state {
                #expect(retryAt.timeIntervalSinceNow <= (attempt == 1 ? 0.03 : 0.06) + 0.01)
            }
        }
        #expect(connector.connectCount == 4)
    }

    @Test func reconnectAnnouncesItselfInTheTerminal() async {
        let first = FakeShell()
        let (session, recorder) = makeSession(FakeConnector([.shell(first), .shell(FakeShell())]))
        await session.connect()
        first.end(.lost)
        #expect(await recorder.waitForOutput("Reconnected"))
    }

    @Test func authFailureDuringReconnectStopsRetrying() async {
        let first = FakeShell()
        let connector = FakeConnector([.shell(first), .fail(AuthRejectedError(method: "password", serverAllows: ["publickey"])), .shell(FakeShell())])
        let (session, recorder) = makeSession(connector)
        await session.connect()
        first.end(.lost)
        let expected = SessionState.disconnected(.error(.authFailed(method: "password", serverAllows: ["publickey"])))
        #expect(await recorder.waitForState { $0 == expected })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(connector.connectCount == 2)
    }

    @Test func givesUpAfterMaxAttempts() async {
        let first = FakeShell()
        let connector = FakeConnector([.shell(first)])   // every further attempt is refused
        let (session, recorder) = makeSession(connector, policy: ReconnectPolicy(maxAttempts: 3, schedule: [.milliseconds(10)]))
        await session.connect()
        first.end(.lost)
        #expect(await recorder.waitForState { $0 == .disconnected(.error(.refused)) })
        #expect(connector.connectCount == 4)
    }

    @Test func disabledAutoReconnectReportsNetworkLost() async {
        let first = FakeShell()
        let connector = FakeConnector([.shell(first), .shell(FakeShell())])
        let (session, recorder) = makeSession(connector, policy: .disabled)
        await session.connect()
        first.end(.lost)
        #expect(await recorder.waitForState { $0 == .disconnected(.error(.networkLost)) })
        #expect(connector.connectCount == 1)
    }

    @Test func disconnectClosesTheShellAndIsFinal() async {
        let shell = FakeShell()
        let connector = FakeConnector([.shell(shell), .shell(FakeShell())])
        let (session, recorder) = makeSession(connector)
        await session.connect()
        await session.disconnect()
        #expect(shell.wasClosed)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.lastState == .disconnected(.userClosed))
        #expect(connector.connectCount == 1)
        #expect(await session.latency() == nil)
    }

    @Test func manualReconnectReplacesTheConnection() async {
        let first = FakeShell(), second = FakeShell()
        let (session, recorder) = makeSession(FakeConnector([.shell(first), .shell(second)]))
        await session.connect()
        await session.reconnect()
        await recorder.settle()
        #expect(first.wasClosed)
        #expect(await recorder.waitForState { isConnected($0) } )
        session.send(Data("x".utf8))
        #expect(second.written.count == 1)
        #expect(first.written.isEmpty)
    }

    @Test func missedKeepAlivesDropAndReconnect() async {
        let first = FakeShell(), second = FakeShell()
        first.setPing(nil)
        let connector = FakeConnector([.shell(first), .shell(second)])
        let (session, recorder) = makeSession(connector, keepAlive: 1)
        // keepAliveSeconds is whole seconds, so this takes ~2 s (two misses).
        await session.connect()
        #expect(await recorder.waitForState(timeout: .seconds(8)) { isReconnecting($0) })
        #expect(await recorder.waitForState(timeout: .seconds(8)) { _ in connector.connectCount == 2 })
        #expect(first.pings >= 2)
    }

    @Test func latencyUsesAPing() async {
        let shell = FakeShell()
        shell.setPing(.milliseconds(33))
        let (session, _) = makeSession(FakeConnector([.shell(shell)]))
        await session.connect()
        #expect(await session.latency() == .milliseconds(33))
    }

    @Test func cancelledPasswordPromptEndsQuietly() async {
        let (session, recorder) = makeSession(FakeConnector([.fail(ConnectCancelledError())]))
        await session.connect()
        await recorder.settle()
        #expect(recorder.lastState == .disconnected(.userClosed))
    }

    @Test func changedHostKeyIsPublishedDeliveredAndCanBeReplaced() async throws {
        let endpoint = HostEndpoint(host: "fake.test")
        let old = HostKey(algorithm: "ssh-ed25519", blobBase64: "AAAA", fingerprintSHA256: "SHA256:old")
        let new = HostKey(algorithm: "ssh-ed25519", blobBase64: "BBBB", fingerprintSHA256: "SHA256:new")
        let store = InMemoryKnownHostsStore(pins: [endpoint: [old]])
        let challenge = HostKeyChallenge(endpoint: endpoint, serverName: "fake", presented: new, lookup: await store.lookup(endpoint, presented: new))
        let prompter = AlwaysTrustPrompter(decision: .trustAndSave)
        let connector = FakeConnector([.fail(HostKeyMismatchError(challenge: challenge)), .shell(FakeShell())])
        let (session, recorder) = makeSession(connector, knownHosts: store, hostKey: prompter)

        await session.connect()
        await recorder.settle()
        #expect(recorder.allStates.contains(.disconnected(.error(.hostKeyMismatch(challengeID: challenge.id)))))
        #expect(prompter.challenges.map(\.id) == [challenge.id])
        #expect(await store.pinned(for: endpoint).map(\.key) == [new], "the new key replaces the pin")
        #expect(connector.connectCount == 2)
        #expect(isConnected(try #require(recorder.lastState)))
    }

    @Test func rejectedChangedHostKeyStaysDisconnected() async {
        let endpoint = HostEndpoint(host: "fake.test")
        let key = HostKey(algorithm: "ssh-ed25519", blobBase64: "BBBB", fingerprintSHA256: "SHA256:new")
        let challenge = HostKeyChallenge(endpoint: endpoint, serverName: nil, presented: key, lookup: .mismatch(pinned: []))
        let connector = FakeConnector([.fail(HostKeyMismatchError(challenge: challenge)), .shell(FakeShell())])
        let (session, recorder) = makeSession(connector, hostKey: AlwaysTrustPrompter(decision: .reject))
        await session.connect()
        await recorder.settle()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.lastState == .disconnected(.error(.hostKeyMismatch(challengeID: challenge.id))))
        #expect(connector.connectCount == 1)
    }

    @Test func resizeDuringConnectIsAppliedOnceConnected() async {
        let shell = FakeShell()
        let connector = FakeConnector([.shell(shell)], delay: .milliseconds(200))
        let (session, recorder) = makeSession(connector)
        let connecting = Task { await session.connect() }
        try? await Task.sleep(for: .milliseconds(50))
        session.resize(cols: 150, rows: 45, pixelWidth: 10, pixelHeight: 20)   // arrives while the PTY is being opened
        await connecting.value
        await recorder.settle()
        #expect(connector.sizesUsed.first?.cols == 80)
        #expect(shell.resizes == [[150, 45, 10, 20]])
    }

    @Test func unchangedSizeIsNotResentAfterConnect() async {
        let shell = FakeShell()
        let (session, recorder) = makeSession(FakeConnector([.shell(shell)]))
        await session.connect()
        await recorder.settle()
        #expect(shell.resizes.isEmpty)
    }

    @Test func reconnectOpensThePTYAtTheLatestSize() async {
        let first = FakeShell()
        let connector = FakeConnector([.shell(first), .shell(FakeShell())])
        let (session, recorder) = makeSession(connector)
        await session.connect()
        session.resize(cols: 99, rows: 31, pixelWidth: 0, pixelHeight: 0)
        first.end(.lost)
        #expect(await recorder.waitForState { _ in connector.connectCount == 2 })
        #expect(connector.sizesUsed.last?.cols == 99)
        #expect(connector.sizesUsed.last?.rows == 31)
    }

    @Test func unclassifiedErrorsAreNotRetried() async {
        let first = FakeShell()
        let connector = FakeConnector([.shell(first), .fail(SessionError.underlying("The private key is passphrase-protected.")), .shell(FakeShell())])
        let (session, recorder) = makeSession(connector)
        await session.connect()
        first.end(.lost)
        #expect(await recorder.waitForState { $0 == .disconnected(.error(.underlying("The private key is passphrase-protected."))) })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(connector.connectCount == 2)
    }

    @Test func everyAttemptSharesTheSessionsConnectOnceList() async {
        let first = FakeShell()
        let connector = FakeConnector([.shell(first), .shell(FakeShell())])
        let (session, recorder) = makeSession(connector)
        await session.connect()
        first.end(.lost)
        #expect(await recorder.waitForState { _ in connector.connectCount == 2 })
        let lists = connector.allowLists
        #expect(lists.count == 2)
        #expect(lists[0] === lists[1])
    }

    @Test func noSecondConnectWhileAHostKeyDecisionIsPending() async {
        let endpoint = HostEndpoint(host: "fake.test")
        let key = HostKey(algorithm: "ssh-ed25519", blobBase64: "BBBB", fingerprintSHA256: "SHA256:new")
        let challenge = HostKeyChallenge(endpoint: endpoint, serverName: nil, presented: key, lookup: .mismatch(pinned: []))
        let connector = FakeConnector([.fail(HostKeyMismatchError(challenge: challenge)), .shell(FakeShell())])
        let prompter = GatedHostKeyPrompter()
        let (session, recorder) = makeSession(connector, hostKey: prompter)

        let first = Task { await session.connect() }
        #expect(await recorder.waitForState { $0 == .disconnected(.error(.hostKeyMismatch(challengeID: challenge.id))) })
        await session.connect()      // ignored: the sheet is still open
        await session.reconnect()    // ignored too
        #expect(connector.connectCount == 1)

        prompter.answer(.reject)
        await first.value
        #expect(connector.connectCount == 1)
    }
}

/// A prompter that waits until the test answers.
@MainActor private final class GatedHostKeyPrompter: HostKeyPrompter {
    private var continuation: CheckedContinuation<HostKeyDecision, Never>?
    func decide(_ challenge: HostKeyChallenge) async -> HostKeyDecision {
        await withCheckedContinuation { continuation = $0 }
    }
    func answer(_ decision: HostKeyDecision) { continuation?.resume(returning: decision); continuation = nil }
}
