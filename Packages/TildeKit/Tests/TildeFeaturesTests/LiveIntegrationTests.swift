import Foundation
import SwiftData
import Synchronization
import Testing
import TildeCore
import TildeStore
@testable import TildeFeatures

/// End-to-end checks of the real service stack (`LiveServices`: the SSH engine, SwiftData host keys, the credential
/// resolver) against the Docker lab in `ci/sshd`. They need `TILDE_SSH_INTEGRATION=1` and the containers up:
///
///     ci/sshd/generate-keys.sh && docker compose -f ci/sshd/docker-compose.yml up -d --build
///     TILDE_SSH_INTEGRATION=1 swift test --filter LiveIntegrationTests
///
/// Everything else is real too: the server is added through the editor model, the session comes from the coordinator,
/// and the unknown host key and password questions are answered the way the sheets would.
private enum Lab {
    static var environment: [String: String] { ProcessInfo.processInfo.environment }
    /// The Docker lab (password user `pwuser`), not the CI single-key server.
    static var isEnabled: Bool { environment["TILDE_SSH_INTEGRATION"] == "1" && environment["TILDE_TEST_SSH_PORT"] == nil }
    static var host: String { environment["TILDE_TEST_SSH_HOST"] ?? "127.0.0.1" }
    static let port = 2201
    static let user = "pwuser"
    static let password = "tilde-test-pw"
}

/// Collects a session's output so the test can wait for text to show up.
private final class OutputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Data>) {
        task = Task { [weak self] in
            for await chunk in stream { self?.append(chunk) }
        }
    }

    private func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    func stop() { task?.cancel() }
}

@MainActor
private struct Rig {
    let container: ModelContainer
    let services: TildeServices
    let secrets: InMemorySecretStore
    let coordinator: SessionCoordinator
    let window = UUID()

    var context: ModelContext { container.mainContext }

    init() throws {
        container = try ModelContainerFactory.make(.inMemory)
        secrets = InMemorySecretStore()
        let defaults = UserDefaults(suiteName: "tilde.live-integration.\(UUID().uuidString)")!
        services = LiveServices.make(container: container, secretStore: secrets, engineDefaults: defaults)
        coordinator = SessionCoordinator(services: services, hostKeyTimeout: .seconds(30), passwordTimeout: .seconds(30))
        coordinator.recordConnections(in: container.mainContext)
        // SwiftData may hand every in-memory container of the same name the same store; start each test with no pins.
        try KnownHostRepository(context: container.mainContext).forget(endpoint: HostEndpoint(host: Lab.host, port: Lab.port))
    }

    /// Adds a server the way the editor does.
    func addServer(auth: AuthMethod, password: String = "") throws -> Server {
        let model = ServerEditorModel(keys: [])
        model.name = "lab"
        model.host = Lab.host
        model.portText = String(Lab.port)
        model.username = Lab.user
        model.auth = auth
        model.password = password
        return try #require(model.save(context: context, secrets: secrets))
    }

    func waitFor(_ what: String, timeout: Duration = .seconds(20), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            try #require(ContinuousClock.now < deadline, "timed out waiting for \(what)")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Answers the unknown-host sheet with "Trust and save" the first time the session asks.
    func trustHostKey() async throws {
        try await waitFor("the host key question") { coordinator.pendingHostKey(in: window) != nil }
        let request = try #require(coordinator.pendingHostKey(in: window))
        #expect(!request.isChangedKey)
        coordinator.answerHostKey(request, .trustAndSave)
    }

    func expectOutput(_ log: OutputLog, contains needle: String) async throws {
        try await waitFor("\"\(needle)\" in the shell output") { log.text.contains(needle) }
    }
}

@MainActor
@Suite(.enabled(if: Lab.isEnabled), .serialized) struct LiveIntegrationTests {
    @Test func savedPasswordServerConnectsAcceptsTheHostKeyAndRunsACommand() async throws {
        let rig = try Rig()
        let server = try rig.addServer(auth: .password, password: Lab.password)

        // The editor stored the password under a fresh id (never the "nothing saved" sentinel) and linked it.
        let secretID = try #require(server.passwordSecretID)
        #expect(secretID != SecretRef.sentinelID)
        #expect(try rig.secrets.read(SecretRef(kind: .password, id: secretID)) == Data(Lab.password.utf8))

        let tab = rig.coordinator.open(ServerMapper.snapshot(server), in: rig.window)
        let log = OutputLog(tab.session.output)
        defer { log.stop() }

        try await rig.trustHostKey()
        try await rig.waitFor("the session to connect") { tab.isConnected }

        tab.session.send(Data("echo tilde-$((40+2))\n".utf8))
        try await rig.expectOutput(log, contains: "tilde-42")

        // The key was pinned: a second session to the same server does not ask again.
        let pinned = try KnownHostRepository(context: rig.context).all()
        #expect(pinned.count == 1)
        #expect(pinned.first?.endpoint == HostEndpoint(host: Lab.host, port: Lab.port).canonical)

        let second = rig.coordinator.open(ServerMapper.snapshot(server), in: rig.window, newSession: true)
        try await rig.waitFor("the second session to connect") { second.isConnected }
        #expect(rig.coordinator.pendingHostKey(in: rig.window) == nil)

        // Connecting recorded `lastConnectedAt` through the repository.
        #expect(server.lastConnectedAt != nil)

        // Deleting the server removes its Keychain secret (the repository returns the orphan, the action deletes it).
        rig.coordinator.close(tab)
        rig.coordinator.close(second)
        ServerActions(context: rig.context, secrets: rig.secrets).delete(server)
        #expect(try rig.secrets.read(SecretRef(kind: .password, id: secretID)) == nil)
        #expect(try rig.context.fetch(FetchDescriptor<Server>()).isEmpty)
    }

    @Test func askEveryTimeServerPromptsWithNotSaved() async throws {
        let rig = try Rig()
        let server = try rig.addServer(auth: .passwordPrompt)
        #expect(server.passwordSecretID == nil)

        // The engine resolves the credential first, so the password question comes before the host key one.
        let tab = rig.coordinator.open(ServerMapper.snapshot(server), in: rig.window)
        try await rig.waitFor("the password question") { rig.coordinator.pendingPassword(in: rig.window) != nil }
        let request = try #require(rig.coordinator.pendingPassword(in: rig.window))
        #expect(request.reason == .notSaved)
        rig.coordinator.answerPassword(request, password: Lab.password)
        try await rig.trustHostKey()
        try await rig.waitFor("the session to connect") { tab.isConnected }
        rig.coordinator.close(tab)
    }

    @Test func savedPasswordWithNoSecretIdPromptsWithNotSaved() async throws {
        let rig = try Rig()
        // `.password` without a secret id: "nothing was saved" (the sentinel), so the sheet must not say "iCloud Keychain".
        let server = try rig.addServer(auth: .passwordPrompt)
        server.authMethodRaw = AuthMethod.password.rawValue
        server.passwordSecretID = nil

        let tab = rig.coordinator.open(ServerMapper.snapshot(server), in: rig.window)
        try await rig.waitFor("the password question") { rig.coordinator.pendingPassword(in: rig.window) != nil }
        #expect(rig.coordinator.pendingPassword(in: rig.window)?.reason == .notSaved)
        rig.coordinator.answerPassword(try #require(rig.coordinator.pendingPassword(in: rig.window)), password: nil)
        try await rig.waitFor("the session to end") { !tab.isLive }
        rig.coordinator.close(tab)
    }

    @Test func secretThatHasNotSyncedYetPromptsWithSecretNotSynced() async throws {
        let rig = try Rig()
        // A password id synced from another device whose Keychain item has not arrived here yet.
        let server = try rig.addServer(auth: .passwordPrompt)
        server.authMethodRaw = AuthMethod.password.rawValue
        server.passwordSecretID = UUID()

        let tab = rig.coordinator.open(ServerMapper.snapshot(server), in: rig.window)
        try await rig.waitFor("the password question") { rig.coordinator.pendingPassword(in: rig.window) != nil }
        let request = try #require(rig.coordinator.pendingPassword(in: rig.window))
        #expect(request.reason == .secretNotSynced)
        rig.coordinator.answerPassword(request, password: Lab.password)
        try await rig.trustHostKey()
        try await rig.waitFor("the session to connect") { tab.isConnected }
        rig.coordinator.close(tab)
    }

    @Test func wrongPasswordShowsTheAuthFailure() async throws {
        let rig = try Rig()
        let server = try rig.addServer(auth: .password, password: "definitely-wrong")
        let tab = rig.coordinator.open(ServerMapper.snapshot(server), in: rig.window)
        try await rig.trustHostKey()
        // The engine asks again once ("rejected"); declining ends in an auth failure.
        try await rig.waitFor("the retry question") { rig.coordinator.pendingPassword(in: rig.window) != nil }
        let retry = try #require(rig.coordinator.pendingPassword(in: rig.window))
        #expect(retry.reason == .rejected)
        rig.coordinator.answerPassword(retry, password: nil)
        try await rig.waitFor("the failure") {
            if case .disconnected = tab.state { true } else { false }
        }
        rig.coordinator.close(tab)
    }
}
