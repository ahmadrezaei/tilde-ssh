import Foundation
import Testing
import TildeCore
import TildeDesign
@testable import TildeFeatures

@MainActor
private func makeCoordinator(hostKeyTimeout: Duration = .seconds(120)) -> SessionCoordinator {
    var services = TildeServices.preview
    services.sessionEngine = FakeSessionEngine(connectDelay: .milliseconds(1))
    return SessionCoordinator(services: services, hostKeyTimeout: hostKeyTimeout)
}

private func challenge(_ lookup: HostKeyLookup = .unknown, host: String = "10.0.1.12") -> HostKeyChallenge {
    HostKeyChallenge(
        endpoint: HostEndpoint(host: host), serverName: "prod-api-01",
        presented: HostKey(algorithm: "ssh-ed25519", blobBase64: "NEW", fingerprintSHA256: "SHA256:new"),
        lookup: lookup
    )
}

private func changedLookup() -> HostKeyLookup {
    let old = HostKey(algorithm: "ssh-ed25519", blobBase64: "OLD", fingerprintSHA256: "SHA256:old")
    return .mismatch(pinned: [PinnedHostKey(key: old, firstSeenAt: .now, trustedOnDevice: "MacBook")])
}

/// Which host-key questions are shown inside their tab (Mac) and which stay with the window.
@MainActor
@Suite struct HostKeyPresentationTests {
    let window = UUID()

    /// Queues a question from `tab` (the way its engine asks) and waits until the coordinator has it.
    private func ask(_ lookup: HostKeyLookup, from tab: SessionTab, in coordinator: SessionCoordinator) async throws -> Task<HostKeyDecision, Never> {
        let prompter = try #require(tab.prompter)
        let before = coordinator.hostKeyQueue.count
        let task = Task { await prompter.decide(challenge(lookup)) }
        await waitUntil { coordinator.hostKeyQueue.count > before }
        return task
    }

    @Test func unknownHostOfATabIsInTabOnTheMacOnly() async throws {
        let coordinator = makeCoordinator()
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        let task = try await ask(.unknown, from: tab, in: coordinator)
        let request = try #require(coordinator.hostKeyQueue.first)
        #expect(HostKeyPresentation.of(request, inTabSupported: true) == .inTab)
        #expect(HostKeyPresentation.of(request, inTabSupported: false) == .windowSheet)
        coordinator.answerHostKey(request, .reject)
        _ = await task.value
    }

    @Test func aQuestionWithoutATabKeepsTheSheet() async throws {
        let coordinator = makeCoordinator()
        let task = Task { await coordinator.decide(challenge()) }
        await waitUntil { !coordinator.hostKeyQueue.isEmpty }
        let request = try #require(coordinator.hostKeyQueue.first)
        #expect(HostKeyPresentation.of(request, inTabSupported: true) == .windowSheet)
        #expect(coordinator.pendingWindowHostKey(in: window, inTabSupported: true)?.id == request.id)
        coordinator.answerHostKey(request, .reject)
        _ = await task.value
    }

    @Test func aChangedKeyIsAlwaysTheTakeover() async throws {
        let coordinator = makeCoordinator()
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        let task = try await ask(changedLookup(), from: tab, in: coordinator)
        let request = try #require(coordinator.hostKeyQueue.first)
        for supported in [true, false] {
            #expect(HostKeyPresentation.of(request, inTabSupported: supported) == .takeover)
            #expect(coordinator.pendingWindowHostKey(in: window, inTabSupported: supported)?.id == request.id)
        }
        #expect(coordinator.pendingInTabHostKey(for: tab.id, inTabSupported: true) == nil)
        coordinator.answerHostKey(request, .reject)
        _ = await task.value
    }

    @Test func anInTabQuestionDoesNotHideALaterQuestionFromTheWindow() async throws {
        let coordinator = makeCoordinator()
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        let tabTask = try await ask(.unknown, from: tab, in: coordinator)
        let tabRequest = try #require(coordinator.hostKeyQueue.first)
        let testTask = Task { await coordinator.decide(challenge(host: "10.0.9.9")) }
        await waitUntil { coordinator.hostKeyQueue.count == 2 }
        let testRequest = try #require(coordinator.hostKeyQueue.last)

        // Mac: the tab's own question is in the tab, the tab-less one is the window's.
        #expect(coordinator.pendingWindowHostKey(in: window, inTabSupported: true)?.id == testRequest.id)
        #expect(coordinator.pendingInTabHostKey(for: tab.id, inTabSupported: true)?.id == tabRequest.id)
        // iPhone and iPad: exactly the old behaviour, the head of the queue.
        #expect(coordinator.pendingWindowHostKey(in: window, inTabSupported: false)?.id == coordinator.pendingHostKey(in: window)?.id)
        #expect(coordinator.pendingWindowHostKey(in: window, inTabSupported: false)?.id == tabRequest.id)
        #expect(coordinator.pendingInTabHostKey(for: tab.id, inTabSupported: false) == nil)

        coordinator.answerHostKey(tabRequest, .reject)
        coordinator.answerHostKey(testRequest, .reject)
        _ = await tabTask.value
        _ = await testTask.value
    }

    @Test func anInTabQuestionIsOnlyForItsOwnTab() async throws {
        let coordinator = makeCoordinator()
        let first = coordinator.open(PreviewServers.prodAPI, in: window)
        let second = coordinator.open(PreviewServers.dbPrimary, in: window)
        let task = try await ask(.unknown, from: first, in: coordinator)
        #expect(coordinator.pendingInTabHostKey(for: first.id, inTabSupported: true) != nil)
        #expect(coordinator.pendingInTabHostKey(for: second.id, inTabSupported: true) == nil)
        coordinator.close(first)
        #expect(await task.value == .reject)
        #expect(coordinator.hostKeyQueue.isEmpty)
    }

    @Test func theQuestionFollowsATabMovedToItsOwnWindow() async throws {
        let coordinator = makeCoordinator()
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        let task = try await ask(.unknown, from: tab, in: coordinator)
        _ = coordinator.moveToOwnWindow(tab)
        let request = try #require(coordinator.pendingInTabHostKey(for: tab.id, inTabSupported: true))
        coordinator.answerHostKey(request, .reject)
        _ = await task.value
    }

    @Test func theDeadlineFollowsTheCoordinatorsTimeout() async throws {
        let coordinator = makeCoordinator(hostKeyTimeout: .seconds(90))
        let task = Task { await coordinator.decide(challenge()) }
        await waitUntil { !coordinator.hostKeyQueue.isEmpty }
        let request = try #require(coordinator.hostKeyQueue.first)
        let deadline = try #require(request.deadline)
        #expect(abs(deadline.timeIntervalSince(request.askedAt) - 90) < 0.001)
        coordinator.answerHostKey(request, .reject)
        _ = await task.value
    }

    @Test func countdownText() {
        #expect(HostKeyCountdown.text(remaining: 108) == "1:48")
        #expect(HostKeyCountdown.text(remaining: 120) == "2:00")
        #expect(HostKeyCountdown.text(remaining: 59.2) == "1:00")
        #expect(HostKeyCountdown.text(remaining: 5) == "0:05")
        #expect(HostKeyCountdown.text(remaining: -3) == "0:00")
        #expect(Duration.milliseconds(1500).timeInterval == 1.5)
    }

    @Test func trustStaysClickOnlyInTheInTabCard() {
        // The in-tab card is built from `UnknownHostAction`, so the sheet's rules carry over.
        #expect(UnknownHostAction.trust.role.bindsReturn == false)
        #expect(UnknownHostAction.reject.role.bindsEscape)
    }
}

@Suite struct SessionStatusSummaryTests {
    private func summary(
        _ server: ServerSnapshot = PreviewServers.prodAPI,
        state: SessionState,
        latency: Int? = nil,
        size: (cols: Int, rows: Int)? = nil,
        keyName: String? = nil,
        awaitingHostKey: Bool = false
    ) -> SessionStatusSummary {
        SessionStatusSummary(server: server, state: state, latencyMilliseconds: latency, terminalSize: size, keyName: keyName, awaitingHostKey: awaitingHostKey)
    }

    private let info = ConnectionInfo(serverVersion: "OpenSSH_9.6", kex: "curve25519-sha256", cipher: "chacha20-poly1305@openssh.com", authenticatedWith: "ssh-ed25519")

    @Test func connectedShowsTheWholeBar() {
        let server = ServerSnapshot(name: "db", target: ConnectionTarget(host: "10.0.2.5", port: 22, username: "postgres"), environment: .prod,
                                    jump: JumpSnapshot(target: ConnectionTarget(host: "bastion", username: "ops")))
        let result = summary(server, state: .connected(info), latency: 31, size: (126, 43), keyName: "macbook-ed25519")
        #expect(result.tone == .prod)
        #expect(result.address == "postgres@10.0.2.5:22")
        #expect(result.jump == "via bastion")
        #expect(result.auth == "macbook-ed25519")
        #expect(result.latency == "31 ms")
        #expect(result.latencyQuality == .good)
        #expect(result.cipher == "chacha20-poly1305@openssh.com")
        #expect(result.size == "126×43")
        #expect(result.encoding == "UTF-8")
        #expect(result.stateText == nil)
    }

    @Test func slowLinkIsFlagged() {
        #expect(summary(state: .connected(info), latency: 183).latencyQuality == .slow)
    }

    @Test func connectedWithoutAProbeOrASizeYet() {
        let result = summary(state: .connected(info))
        #expect(result.latency == nil)
        #expect(result.size == nil)
        #expect(result.cipher != nil)
    }

    @Test func noJumpHostMeansNoViaSegment() {
        let direct = ServerSnapshot(name: "a", target: ConnectionTarget(host: "10.0.1.12", username: "deploy"))
        #expect(summary(direct, state: .connected(info)).jump == nil)
    }

    @Test func authLabels() {
        #expect(SessionStatusSummary.authLabel(.key, keyName: "deploy-key") == "deploy-key")
        #expect(SessionStatusSummary.authLabel(.key, keyName: nil) == "key")
        #expect(SessionStatusSummary.authLabel(.password, keyName: "ignored") == "password")
        #expect(SessionStatusSummary.authLabel(.passwordPrompt, keyName: nil) == "password prompt")
    }

    @Test func statesThatAreNotConnectedReplaceLatencyAndCipher() {
        let cases: [(SessionState, String, StatusReadout.Quality)] = [
            (.idle, "Connecting…", .busy),
            (.connecting(phase: .tcp), "Connecting…", .busy),
            (.reconnecting(attempt: 2, retryAt: .now), "Reconnecting…", .slow),
            (.disconnected(.userClosed), "Disconnected", .idle),
            (.disconnected(.exited(status: 0)), "Disconnected", .idle),
            (.disconnected(.error(.refused)), "Connection failed", .bad)
        ]
        for (state, text, quality) in cases {
            let result = summary(state: state, latency: 23)
            #expect(result.stateText == text)
            #expect(result.stateQuality == quality)
            #expect(result.latency == nil)
            #expect(result.cipher == nil)
        }
    }

    @Test func waitingForAHostKeyWinsOverTheConnectionState() {
        let result = summary(state: .connecting(phase: .hostKey), awaitingHostKey: true)
        #expect(result.stateText == "Verify host key")
    }

    @Test func toolbarSubtitleAddsTheJumpHost() {
        let plain = ServerSnapshot(name: "a", target: ConnectionTarget(host: "10.0.1.12", port: 22, username: "deploy"))
        #expect(SessionContainer.macSubtitle(for: plain) == "deploy@10.0.1.12")
        var jumped = plain
        jumped.target.port = 2222
        jumped.jump = JumpSnapshot(target: ConnectionTarget(host: "bastion", username: "ops"))
        #expect(SessionContainer.macSubtitle(for: jumped) == "deploy@10.0.1.12:2222 · via bastion")
    }
}
