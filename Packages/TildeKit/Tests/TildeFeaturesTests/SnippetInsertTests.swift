import Foundation
import Synchronization
import Testing
import TildeCore
@testable import TildeFeatures

/// An `EchoTerminalSession` that remembers what was typed into it.
private final class RecordingSession: TerminalSession, Sendable {
    private let inner: EchoTerminalSession
    private let log = Mutex<[String]>([])

    init(_ inner: EchoTerminalSession) { self.inner = inner }

    var sent: [String] { log.withLock { $0 } }

    var id: UUID { inner.id }
    var server: ServerSnapshot { inner.server }
    var output: AsyncStream<Data> { inner.output }
    var states: AsyncStream<SessionState> { inner.states }
    func connect() async { await inner.connect() }
    func reconnect() async { await inner.reconnect() }
    func disconnect() async { await inner.disconnect() }
    func latency() async -> Duration? { await inner.latency() }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) { inner.resize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
    func send(_ bytes: Data) {
        log.withLock { $0.append(String(decoding: bytes, as: UTF8.self)) }
        inner.send(bytes)
    }
}

private final class RecordingEngine: SessionEngine, Sendable {
    private let sessions = Mutex<[RecordingSession]>([])
    var last: RecordingSession? { sessions.withLock { $0.last } }

    func makeSession(_ request: SessionRequest, credentials: any CredentialResolver, knownHosts: any KnownHostsStore,
                     hostKeyPrompter: any HostKeyPrompter, passwordPrompter: any PasswordPrompter) -> any TerminalSession {
        let session = RecordingSession(EchoTerminalSession(server: request.server, connectDelay: .milliseconds(1)))
        sessions.withLock { $0.append(session) }
        return session
    }

    func test(_ request: SessionRequest, credentials: any CredentialResolver, knownHosts: any KnownHostsStore,
              hostKeyPrompter: any HostKeyPrompter, passwordPrompter: any PasswordPrompter) async -> Result<ConnectionInfo, SessionError> {
        .failure(.refused)
    }

    func runCommand(_ command: String, on request: SessionRequest, credentials: any CredentialResolver,
                    knownHosts: any KnownHostsStore) async throws -> (stdout: Data, exitStatus: Int) { (Data(), 0) }
}

/// Snippets typed from the palette: one-liners go straight to the session, multi-line ones ask first on PROD.
@MainActor
@Suite struct SnippetInsertTests {
    let window = UUID()

    private func connectedTab(_ server: ServerSnapshot) async -> (SessionCoordinator, SessionTab, RecordingSession) {
        let engine = RecordingEngine()
        var services = TildeServices.preview
        services.sessionEngine = engine
        let coordinator = SessionCoordinator(services: services)
        let tab = coordinator.open(server, in: window)
        await waitUntil { tab.isConnected }
        return (coordinator, tab, engine.last!)
    }

    @Test func oneLineRunSnippetOnProdDoesNotAsk() async {
        let (coordinator, tab, session) = await connectedTab(PreviewServers.prodAPI)
        let snippet = SnippetSnapshot(name: "df", command: "df -h", runOnInsert: true)
        #expect(coordinator.insert(snippet, in: window))
        #expect(tab.pasteRequest == nil)
        #expect(session.sent == ["df -h\r"])
    }

    @Test func multiLineSnippetOnProdAsksBeforeSending() async {
        let (coordinator, tab, session) = await connectedTab(PreviewServers.prodAPI)
        let snippet = SnippetSnapshot(name: "deploy", command: "git pull\nmake deploy\nsystemctl restart api", runOnInsert: true)
        #expect(coordinator.insert(snippet, in: window))
        await waitUntil { tab.pasteRequest != nil }
        let request = tab.pasteRequest
        #expect(request?.lineCount == 3)
        #expect(request?.previewLines.first == "git pull")
        #expect(session.sent.isEmpty)

        tab.answerPaste(true)
        await waitUntil { !session.sent.isEmpty }
        #expect(session.sent == ["git pull\nmake deploy\nsystemctl restart api\r"])
    }

    @Test func decliningTheConfirmationSendsNothing() async {
        let (coordinator, tab, session) = await connectedTab(PreviewServers.prodAPI)
        let snippet = SnippetSnapshot(name: "two", command: "a\nb", runOnInsert: false)
        _ = coordinator.insert(snippet, in: window)
        await waitUntil { tab.pasteRequest != nil }
        tab.answerPaste(false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.sent.isEmpty)
    }

    @Test func multiLineSnippetOnADevServerIsNotHeldBackInTheDefaultMode() async {
        let (coordinator, tab, session) = await connectedTab(PreviewServers.devBox)
        let snippet = SnippetSnapshot(name: "two", command: "a\nb", runOnInsert: false)
        _ = coordinator.insert(snippet, in: window)
        #expect(tab.pasteRequest == nil)
        #expect(session.sent == ["a\nb"])
    }
}

@Suite struct PasteModeTests {
    @Test func modes() {
        #expect(PasteConfirmMode.prodOnly.requiresConfirmation(for: .prod))
        #expect(!PasteConfirmMode.prodOnly.requiresConfirmation(for: .staging))
        #expect(PasteConfirmMode.always.requiresConfirmation(for: .none))
        #expect(!PasteConfirmMode.never.requiresConfirmation(for: .prod))
    }

    @MainActor @Test func linesSkipEmptyOnes() {
        #expect(SessionTab.lines(of: "a\r\nb\n\nc\r") == ["a", "b", "c"])
        #expect(SessionTab.lines(of: "single") == ["single"])
        #expect(SessionTab.lines(of: "\n\n").isEmpty)
    }
}
