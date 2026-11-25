import Foundation
import Testing
import TildeCore
@testable import TildeSSH

/// End-to-end tests against the OpenSSH 9.7 containers in `ci/sshd`. Skipped unless `TILDE_SSH_INTEGRATION=1`.
@Suite(.serialized, .enabled(if: Lab.isDockerLabEnabled))
@MainActor
struct IntegrationTests {
    let engine = CitadelSessionEngine(options: .init(reconnect: .disabled))

    // MARK: Helpers

    private func request(_ server: ServerSnapshot, timeout: Duration = .seconds(10)) -> SessionRequest {
        SessionRequest(server: server, connectTimeout: timeout)
    }

    private func test(
        _ server: ServerSnapshot, credentials: LabCredentials = LabCredentials(),
        knownHosts: InMemoryKnownHostsStore = InMemoryKnownHostsStore(), hostKey: AlwaysTrustPrompter = AlwaysTrustPrompter(),
        password: ScriptedPasswordPrompter = ScriptedPasswordPrompter([])
    ) async -> Result<ConnectionInfo, SessionError> {
        await engine.test(request(server), credentials: credentials, knownHosts: knownHosts, hostKeyPrompter: hostKey, passwordPrompter: password)
    }

    private func openShell(
        _ server: ServerSnapshot, credentials: LabCredentials = LabCredentials(), engine: CitadelSessionEngine? = nil,
        knownHosts: InMemoryKnownHostsStore = InMemoryKnownHostsStore(), hostKey: AlwaysTrustPrompter = AlwaysTrustPrompter(),
        password: ScriptedPasswordPrompter = ScriptedPasswordPrompter([])
    ) async -> (any TerminalSession, SessionRecorder) {
        let session = (engine ?? self.engine).makeSession(
            request(server), credentials: credentials, knownHosts: knownHosts, hostKeyPrompter: hostKey, passwordPrompter: password
        )
        let recorder = SessionRecorder(session)
        await session.connect()
        await recorder.settle()
        return (session, recorder)
    }

    // MARK: Authentication matrix

    @Test func passwordAuthRunsACommandAndReportsExitStatus() async throws {
        let (session, recorder) = await openShell(Lab.server(user: "pwuser"))
        guard case .connected(let info)? = recorder.lastState else { Issue.record("not connected: \(String(describing: recorder.lastState))"); return }
        #expect(info.serverVersion.contains("OpenSSH"))
        #expect(info.authenticatedWith == "password")
        #expect(info.kex != "unknown")

        session.send(Data("echo $((6*7))\n".utf8))
        #expect(await recorder.waitForOutput("42"))
        session.send(Data("exit 3\n".utf8))
        #expect(await recorder.waitForState { $0 == .disconnected(.exited(status: 3)) })
    }

    @Test(arguments: [
        ("ed25519user", "id_ed25519", "ssh-ed25519"),
        ("ecdsauser", "id_ecdsa", "ecdsa-sha2-nistp256"),
        ("ecdsauser", "id_ecdsa384", "ecdsa-sha2-nistp384"),
        ("ecdsauser", "id_ecdsa521", "ecdsa-sha2-nistp521"),
    ])
    func keyAuth(user: String, keyFile: String, expectedAlgorithm: String) async throws {
        let result = await test(Lab.server(user: user, auth: .key), credentials: LabCredentials(keyFile: keyFile))
        guard case .success(let info) = result else { Issue.record("\(result)"); return }
        #expect(info.authenticatedWith == expectedAlgorithm)
    }

    /// The server is OpenSSH 9.7, which rejects `ssh-rsa` (SHA-1) signatures by default. Success here proves the
    /// RFC 8332 `rsa-sha2-512` path works, for 2048 and 4096 bit keys.
    @Test(arguments: ["id_rsa", "id_rsa4096"])
    func rsaKeyAuthUsesSHA2(keyFile: String) async throws {
        let result = await test(Lab.server(user: "rsauser", auth: .key), credentials: LabCredentials(keyFile: keyFile))
        guard case .success(let info) = result else { Issue.record("\(result)"); return }
        #expect(info.authenticatedWith == "rsa-sha2-512")
    }

    @Test func wrongKeyReportsWhatTheServerAccepts() async {
        // The ed25519 key is not installed for `pwuser`.
        let result = await test(Lab.server(user: "pwuser", auth: .key), credentials: LabCredentials(keyFile: "id_ed25519"))
        guard case .failure(.authFailed(let method, let allows)) = result else { Issue.record("\(result)"); return }
        #expect(method == "publickey")
        #expect(allows.contains("password"))
    }

    @Test func wrongPasswordWithoutPrompterFails() async {
        let prompter = ScriptedPasswordPrompter([nil])
        let result = await test(Lab.server(user: "pwuser"), credentials: LabCredentials(password: "nope"), password: prompter)
        guard case .failure(.authFailed(let method, _)) = result else { Issue.record("\(result)"); return }
        #expect(method == "password")
        #expect(prompter.reasons == [.rejected])
    }

    @Test func rejectedPasswordIsReplacedFromThePrompt() async {
        let prompter = ScriptedPasswordPrompter([Lab.password])
        let result = await test(Lab.server(user: "pwuser"), credentials: LabCredentials(password: "nope"), password: prompter)
        guard case .success = result else { Issue.record("\(result)"); return }
        #expect(prompter.reasons == [.rejected])
    }

    @Test func promptAuthAsksBeforeConnecting() async {
        let prompter = ScriptedPasswordPrompter([Lab.password])
        let server = Lab.server(user: "pwuser", auth: .passwordPrompt)
        let result = await test(server, password: prompter)
        guard case .success = result else { Issue.record("\(result)"); return }
        #expect(prompter.reasons == [.notSaved])
    }

    // MARK: Host keys

    @Test func unknownHostIsPromptedOnceThenTrusted() async throws {
        let store = InMemoryKnownHostsStore()
        let prompter = AlwaysTrustPrompter(decision: .trustAndSave)
        let server = Lab.server(user: "pwuser")

        guard case .success = await test(server, knownHosts: store, hostKey: prompter) else { Issue.record("first connect failed"); return }
        #expect(prompter.challenges.count == 1)
        #expect(prompter.challenges[0].lookup == .unknown)
        #expect(await store.pinned(for: HostEndpoint(host: Lab.host, port: Lab.targetPort)).count == 1)

        guard case .success = await test(server, knownHosts: store, hostKey: prompter) else { Issue.record("second connect failed"); return }
        #expect(prompter.challenges.count == 1, "a trusted host must not prompt again")
    }

    @Test func rejectingAnUnknownHostStopsTheConnection() async {
        let prompter = AlwaysTrustPrompter(decision: .reject)
        let result = await test(Lab.server(user: "pwuser"), hostKey: prompter)
        #expect(result == .failure(.hostKeyRejected))
    }

    @Test func connectOnceDoesNotPin() async {
        let store = InMemoryKnownHostsStore()
        let result = await test(Lab.server(user: "pwuser"), knownHosts: store, hostKey: AlwaysTrustPrompter(decision: .connectOnce))
        guard case .success = result else { Issue.record("\(result)"); return }
        #expect(await store.pinned(for: HostEndpoint(host: Lab.host, port: Lab.targetPort)).isEmpty)
    }

    /// A changed host key aborts during key exchange: the server must never see a login attempt.
    @Test func changedHostKeyAbortsBeforeAnyCredentialIsSent() async throws {
        let endpoint = HostEndpoint(host: Lab.host, port: Lab.targetPort)
        let impostor = HostKey(algorithm: "ssh-ed25519", blobBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIGRvIG5vdCB0cnVzdCB0aGlzIGtleSBhdCBhbGwhISE=", fingerprintSHA256: "SHA256:impostor")
        let store = InMemoryKnownHostsStore(pins: [endpoint: [impostor]])
        let prompter = AlwaysTrustPrompter(decision: .reject)

        let before = try Lab.compose("logs", "--no-log-prefix", "target")
        let result = await test(Lab.server(user: "pwuser"), knownHosts: store, hostKey: prompter)
        guard case .failure(.hostKeyMismatch(let id)) = result else { Issue.record("\(result)"); return }
        #expect(prompter.challenges.count == 1)
        #expect(prompter.challenges[0].id == id)
        guard case .mismatch = prompter.challenges[0].lookup else { Issue.record("expected mismatch lookup"); return }

        try await Task.sleep(for: .milliseconds(500))
        let after = try Lab.compose("logs", "--no-log-prefix", "target")
        let newLog = String(after.dropFirst(before.count))
        #expect(!newLog.contains("Accepted password"), "credentials reached the server")
        #expect(!newLog.contains("Failed password"), "credentials reached the server")
    }

    @Test func trustingTheNewKeyReconnectsWithTheNewPin() async throws {
        let endpoint = HostEndpoint(host: Lab.host, port: Lab.targetPort)
        let old = HostKey(algorithm: "ssh-ed25519", blobBase64: "AAAAC3NzaC1lZDI1NTE5AAAAIGRvIG5vdCB0cnVzdCB0aGlzIGtleSBhdCBhbGwhISE=", fingerprintSHA256: "SHA256:old")
        let store = InMemoryKnownHostsStore(pins: [endpoint: [old]])
        let prompter = AlwaysTrustPrompter(decision: .trustAndSave)

        let (_, recorder) = await openShell(Lab.server(user: "pwuser"), knownHosts: store, hostKey: prompter)
        #expect(recorder.allStates.contains(.disconnected(.error(.hostKeyMismatch(challengeID: prompter.challenges[0].id)))))
        guard case .connected? = recorder.lastState else { Issue.record("not reconnected: \(String(describing: recorder.lastState))"); return }
        #expect(await store.pinned(for: endpoint).count == 1)
        #expect(await store.pinned(for: endpoint).first?.key.fingerprintSHA256 != "SHA256:old")
    }

    @Test func connectPhasesAreReportedInOrder() async {
        let (session, recorder) = await openShell(Lab.server(user: "pwuser"))
        let phases = recorder.allStates.compactMap { state -> ConnectPhase? in
            if case .connecting(let phase) = state { phase } else { nil }
        }
        // `.resolving` first, then each phase once the connection reaches it.
        #expect(phases.first == .resolving)
        let expected: [ConnectPhase] = [.tcp, .handshake, .hostKey, .authenticating, .openingShell]
        var cursor = phases.startIndex
        for phase in expected {
            guard let found = phases[cursor...].firstIndex(of: phase) else { Issue.record("missing phase \(phase) in \(phases)"); return }
            cursor = found
        }
        await session.disconnect()
    }

    /// The clock stops while the host key sheet is open: a 2.5 s decision must not fail a 2 s connect timeout.
    @Test func slowHostKeyDecisionDoesNotConsumeTheConnectTimeout() async {
        let prompter = SlowHostKeyPrompter(delay: .milliseconds(2500))
        let result = await engine.test(
            request(Lab.server(user: "pwuser"), timeout: .seconds(2)), credentials: LabCredentials(),
            knownHosts: InMemoryKnownHostsStore(), hostKeyPrompter: prompter, passwordPrompter: ScriptedPasswordPrompter([])
        )
        guard case .success = result else { Issue.record("\(result)"); return }
    }

    // MARK: Dropbear (a second SSH implementation)

    @Test(arguments: [("ed25519user", "id_ed25519"), ("ecdsauser", "id_ecdsa")])
    func dropbearKeyAuth(user: String, keyFile: String) async {
        let result = await test(Lab.server(user: user, port: Lab.dropbearPort, auth: .key), credentials: LabCredentials(keyFile: keyFile))
        guard case .success(let info) = result else { Issue.record("\(result)"); return }
        #expect(info.serverVersion.contains("dropbear"))
    }

    /// Known limitation, pinned down here so a NIOSSH change that fixes it shows up: NIOSSH writes the public key
    /// blob header and the algorithm name from one string, so our `rsa-sha2-*` offers carry `rsa-sha2-*` as the
    /// blob header. OpenSSH accepts that; Dropbear does not. Dropbear RSA users need `allowLegacySSHRSA`.
    @Test func dropbearRSARequiresTheLegacyFallback() async {
        let server = Lab.server(user: "rsauser", port: Lab.dropbearPort, auth: .key)
        let strict = await test(server, credentials: LabCredentials(keyFile: "id_rsa"))
        guard case .failure(.authFailed(let method, _)) = strict else { Issue.record("expected authFailed, got \(strict)"); return }
        #expect(method == "publickey")

        let legacy = CitadelSessionEngine(options: .init(reconnect: .disabled, allowLegacySSHRSA: true))
        let result = await legacy.test(
            request(server), credentials: LabCredentials(keyFile: "id_rsa"), knownHosts: InMemoryKnownHostsStore(),
            hostKeyPrompter: AlwaysTrustPrompter(), passwordPrompter: ScriptedPasswordPrompter([])
        )
        guard case .success(let info) = result else { Issue.record("\(result)"); return }
        #expect(info.authenticatedWith == "ssh-rsa")
    }

    /// OpenSSH 9.7 refuses SHA-1 `ssh-rsa`, so enabling the legacy fallback must not change how a modern server is handled.
    @Test func legacyFallbackStillUsesSHA2OnModernServers() async {
        let legacy = CitadelSessionEngine(options: .init(reconnect: .disabled, allowLegacySSHRSA: true))
        let result = await legacy.test(
            request(Lab.server(user: "rsauser", auth: .key)), credentials: LabCredentials(keyFile: "id_rsa"),
            knownHosts: InMemoryKnownHostsStore(), hostKeyPrompter: AlwaysTrustPrompter(), passwordPrompter: ScriptedPasswordPrompter([])
        )
        guard case .success(let info) = result else { Issue.record("\(result)"); return }
        #expect(info.authenticatedWith == "rsa-sha2-512")
    }

    @Test func dropbearPasswordAuthAndShell() async {
        let (session, recorder) = await openShell(Lab.server(user: "pwuser", port: Lab.dropbearPort))
        guard case .connected? = recorder.lastState else { Issue.record("not connected: \(recorder.allStates)"); return }
        session.send(Data("echo $((6*7))\n".utf8))
        #expect(await recorder.waitForOutput("42"))
        await session.disconnect()
    }

    // MARK: Flow control

    /// Output nobody reads must stop the server instead of piling up in memory, and reading must resume afterwards.
    @Test func unreadOutputIsBoundedAndFlowResumesWhenConsumed() async throws {
        let server = Lab.server(user: "pwuser")
        let session = CitadelSessionEngine(options: .init(reconnect: .disabled)).makeSession(
            request(server), credentials: LabCredentials(), knownHosts: InMemoryKnownHostsStore(),
            hostKeyPrompter: AlwaysTrustPrompter(), passwordPrompter: ScriptedPasswordPrompter([])
        ) as! CitadelTerminalSession
        await session.connect()

        // 40 MB of text, then a marker. Nobody consumes `output` yet.
        let total = 40_000_000
        session.send(Data("head -c \(total) /dev/zero | tr '\\0' 'x'; echo; echo flood-finished\n".utf8))
        try await Task.sleep(for: .seconds(3))
        let held = session.pendingOutputBytes
        #expect(held >= 1_000_000, "the flood should have started (\(held) bytes held)")
        #expect(held < 12_000_000, "unconsumed output must stay bounded (\(held) bytes held, \(total) sent)")

        // Now consume everything: the remote side must resume and finish.
        var received = 0
        var tail = ""
        for await chunk in session.output {
            received += chunk.count
            tail = String((tail + String(decoding: chunk.suffix(64), as: UTF8.self)).suffix(128))
            if tail.contains("flood-finished\r\n") && received >= total { break }
        }
        #expect(received >= total)
        #expect(session.pendingOutputBytes < 1024)
        await session.disconnect()
    }

    // MARK: Shell behaviour

    @Test func ptyTermEnvAndResize() async throws {
        let (session, recorder) = await openShell(Lab.server(user: "pwuser"))
        session.send(Data("echo term=$TERM\n".utf8))
        #expect(await recorder.waitForOutput("term=xterm-256color"))
        session.resize(cols: 101, rows: 33, pixelWidth: 0, pixelHeight: 0)
        try await Task.sleep(for: .milliseconds(300))
        session.send(Data("stty size\n".utf8))
        #expect(await recorder.waitForOutput("33 101"))
        await session.disconnect()
        #expect(recorder.lastState == .disconnected(.userClosed))
    }

    @Test func latencyAndKeepAliveRoundTrip() async throws {
        let (session, recorder) = await openShell(Lab.server(user: "pwuser", keepAlive: 1))
        let rtt = await session.latency()
        #expect(rtt != nil)
        #expect((rtt ?? .seconds(9)) < .seconds(2))
        // Several keep-alive intervals pass without the session dying.
        try await Task.sleep(for: .seconds(3.5))
        guard case .connected? = recorder.lastState else { Issue.record("dropped: \(String(describing: recorder.lastState))"); return }
        await session.disconnect()
    }

    @Test func autoTmuxAttachesNamedSession() async throws {
        let server = ServerSnapshot(
            name: "lab", target: ConnectionTarget(host: Lab.host, port: Lab.targetPort, username: "pwuser"), auth: .password,
            passwordSecretID: UUID(), startupCommand: "echo startup-ran", autoTmux: true, tmuxSessionName: "tilde-it", keepAliveSeconds: 0
        )
        let (session, recorder) = await openShell(server)
        #expect(await recorder.waitForOutput("startup-ran"))
        session.send(Data("tmux display-message -p 'in-session=#S'\n".utf8))
        #expect(await recorder.waitForOutput("in-session=tilde-it"))
        await session.disconnect()
    }

    // MARK: Jump host

    @Test func connectsThroughTheBastion() async throws {
        let jump = JumpSnapshot(
            target: ConnectionTarget(host: Lab.host, port: Lab.bastionPort, username: "pwuser"), auth: .password, passwordSecretID: UUID()
        )
        // `target` is only resolvable (and its port 22 only reachable) from inside the compose network.
        let server = Lab.server(user: "pwuser", port: 22, host: "target", jump: jump)
        let prompter = AlwaysTrustPrompter(decision: .trustAndSave)
        let (session, recorder) = await openShell(server, hostKey: prompter)
        guard case .connected? = recorder.lastState else { Issue.record("not connected: \(String(describing: recorder.lastState))"); return }
        #expect(prompter.challenges.map(\.endpoint.host) == [Lab.host, "target"])
        session.send(Data("hostname\n".utf8))
        #expect(await recorder.waitForOutput("target"))
        await session.disconnect()
    }

    // MARK: runCommand

    @Test func runCommandReturnsStdoutAndExitStatus() async throws {
        let store = InMemoryKnownHostsStore()
        try await store.trust(try await hostKey(port: Lab.targetPort), for: HostEndpoint(host: Lab.host, port: Lab.targetPort), replacing: false)
        let ok = try await engine.runCommand("echo hello; exit 0", on: request(Lab.server(user: "pwuser")), credentials: LabCredentials(), knownHosts: store)
        #expect(String(decoding: ok.stdout, as: UTF8.self) == "hello\n")
        #expect(ok.exitStatus == 0)
        let failed = try await engine.runCommand("exit 7", on: request(Lab.server(user: "pwuser")), credentials: LabCredentials(), knownHosts: store)
        #expect(failed.exitStatus == 7)
    }

    @Test func runCommandRejectsUnknownHosts() async {
        do {
            _ = try await engine.runCommand("true", on: request(Lab.server(user: "pwuser")), credentials: LabCredentials(), knownHosts: InMemoryKnownHostsStore())
            Issue.record("expected a failure")
        } catch {
            #expect(error as? SessionError == .hostKeyRejected)
        }
    }

    /// Learns the target's host key by connecting once with a recording prompter.
    private func hostKey(port: Int) async throws -> HostKey {
        let prompter = AlwaysTrustPrompter(decision: .connectOnce)
        _ = await test(Lab.server(user: "pwuser", port: port), hostKey: prompter)
        return try #require(prompter.challenges.first?.presented)
    }

    // MARK: Algorithms and failures

    @Test func legacyServerUsesTheCitadelAlgorithms() async {
        let result = await test(Lab.server(user: "pwuser", port: Lab.legacyPort))
        guard case .success(let info) = result else { Issue.record("\(result)"); return }
        #expect(info.kex == "diffie-hellman-group14-sha256")
        #expect(info.cipher == "aes128-ctr")
    }

    @Test func noCommonKeyExchangeListsTheServersOffer() async {
        let result = await test(Lab.server(user: "pwuser", port: Lab.noKexPort))
        guard case .failure(.noCommonAlgorithm(let kind, let offered)) = result else { Issue.record("\(result)"); return }
        #expect(kind == "kex")
        #expect(offered.contains("diffie-hellman-group-exchange-sha256"))
    }

    @Test func connectionRefused() async {
        let result = await test(Lab.server(user: "pwuser", port: 1))
        #expect(result == .failure(.refused))
    }

    @Test func unresolvableHost() async {
        let result = await test(Lab.server(user: "pwuser", host: "no-such-host.invalid"))
        #expect(result == .failure(.dnsFailure(host: "no-such-host.invalid")))
    }

    // MARK: Reconnect

    @Test func reconnectsAfterTheServerRestarts() async throws {
        let reconnecting = CitadelSessionEngine(options: .init(reconnect: ReconnectPolicy(maxAttempts: 20, schedule: [.milliseconds(500)])))
        let (session, recorder) = await openShell(Lab.server(user: "pwuser", port: Lab.legacyPort), engine: reconnecting)
        guard case .connected? = recorder.lastState else { Issue.record("not connected: \(recorder.allStates)"); return }

        try Lab.compose("restart", "legacy")
        #expect(await recorder.waitForState(timeout: .seconds(30)) { if case .reconnecting = $0 { true } else { false } })
        var sawReconnect = false
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline, !sawReconnect {
            try await Task.sleep(for: .milliseconds(100))
            if case .connected? = recorder.lastState { sawReconnect = true }
        }
        #expect(sawReconnect)
        guard case .connected? = recorder.lastState else { Issue.record("not reconnected: \(String(describing: recorder.lastState))"); return }
        session.send(Data("echo back-again\n".utf8))
        #expect(await recorder.waitForOutput("back-again"))
        await session.disconnect()
    }
}

@MainActor private final class SlowHostKeyPrompter: HostKeyPrompter {
    let delay: Duration
    init(delay: Duration) { self.delay = delay }
    func decide(_ challenge: HostKeyChallenge) async -> HostKeyDecision {
        try? await Task.sleep(for: delay)
        return .trustAndSave
    }
}
