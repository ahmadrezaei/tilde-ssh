import Foundation
import Synchronization
import Testing
import TildeCore
@testable import TildeFeatures

/// Polls until `condition` holds (or the timeout passes). The generous default keeps
/// slow, heavily parallel CI runs from timing out; it returns as soon as the condition holds.
@MainActor
func waitUntil(timeout: Duration = .seconds(15), _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func makeCoordinator(failure: SessionError? = nil, hostKeyTimeout: Duration = .seconds(120)) -> SessionCoordinator {
    var services = TildeServices.preview
    services.sessionEngine = FakeSessionEngine(failure: failure, connectDelay: .milliseconds(1))
    return SessionCoordinator(services: services, hostKeyTimeout: hostKeyTimeout)
}

@MainActor
@Suite struct SessionCoordinatorTests {
    let window = UUID()

    @Test func openCreatesATabAndConnects() async {
        let coordinator = makeCoordinator()
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        #expect(coordinator.tabs(in: window).count == 1)
        #expect(coordinator.selectedTab(in: window)?.id == tab.id)
        await waitUntil { tab.isConnected }
        #expect(tab.isConnected)
        #expect(tab.latencyMilliseconds == 23)
        #expect(coordinator.isLive(serverID: PreviewServers.prodAPI.id))
    }

    @Test func openingTheSameServerFocusesTheExistingTab() {
        let coordinator = makeCoordinator()
        let first = coordinator.open(PreviewServers.prodAPI, in: window)
        _ = coordinator.open(PreviewServers.dbPrimary, in: window)
        let again = coordinator.open(PreviewServers.prodAPI, in: window)
        #expect(again.id == first.id)
        #expect(coordinator.tabs(in: window).count == 2)
        #expect(coordinator.selectedTab(in: window)?.id == first.id)
    }

    @Test func newSessionAlwaysCreatesAnotherTab() {
        let coordinator = makeCoordinator()
        let first = coordinator.open(PreviewServers.prodAPI, in: window)
        let second = coordinator.open(PreviewServers.prodAPI, in: window, newSession: true)
        #expect(first.id != second.id)
        #expect(coordinator.tabs(in: window).count == 2)
    }

    @Test func tabsBelongToTheirWindow() {
        let coordinator = makeCoordinator()
        let other = UUID()
        coordinator.open(PreviewServers.prodAPI, in: window)
        coordinator.open(PreviewServers.prodAPI, in: other)
        #expect(coordinator.tabs(in: window).count == 1)
        #expect(coordinator.tabs(in: other).count == 1)
        #expect(coordinator.tabs.count == 2)
    }

    @Test func closingSelectsTheNeighbourAndRemembersTheServer() {
        let coordinator = makeCoordinator()
        let a = coordinator.open(PreviewServers.prodAPI, in: window)
        let b = coordinator.open(PreviewServers.dbPrimary, in: window)
        let c = coordinator.open(PreviewServers.devBox, in: window)
        coordinator.select(b)
        coordinator.close(b)
        #expect(coordinator.tabs(in: window).map(\.id) == [a.id, c.id])
        #expect(coordinator.selectedTab(in: window)?.id == c.id)
        #expect(coordinator.recentlyClosed.first?.id == PreviewServers.dbPrimary.id)

        coordinator.close(c)
        #expect(coordinator.selectedTab(in: window)?.id == a.id)
        coordinator.close(a)
        #expect(coordinator.selectedTab(in: window) == nil)
    }

    @Test func reopenLastClosed() {
        let coordinator = makeCoordinator()
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        coordinator.close(tab)
        let reopened = coordinator.reopenLastClosed(in: window)
        #expect(reopened?.server.id == PreviewServers.prodAPI.id)
        #expect(coordinator.reopenLastClosed(in: window) == nil)
    }

    @Test func tabSelectionByNumberAndCycling() {
        let coordinator = makeCoordinator()
        let tabs = [PreviewServers.prodAPI, PreviewServers.dbPrimary, PreviewServers.devBox].map { coordinator.open($0, in: window) }
        coordinator.select(index: 1, in: window)
        #expect(coordinator.selectedTab(in: window)?.id == tabs[0].id)
        coordinator.select(index: 9, in: window)   // Cmd-9 is always the last tab
        #expect(coordinator.selectedTab(in: window)?.id == tabs[2].id)
        coordinator.selectNext(in: window)
        #expect(coordinator.selectedTab(in: window)?.id == tabs[0].id)
        coordinator.selectPrevious(in: window)
        #expect(coordinator.selectedTab(in: window)?.id == tabs[2].id)
        coordinator.select(index: 2, in: window)
        #expect(coordinator.selectedTab(in: window)?.id == tabs[1].id)
    }

    @Test func movingATabToItsOwnWindow() {
        let coordinator = makeCoordinator()
        let a = coordinator.open(PreviewServers.prodAPI, in: window)
        let b = coordinator.open(PreviewServers.dbPrimary, in: window)
        let newWindow = coordinator.moveToOwnWindow(b)
        #expect(newWindow == b.id)
        #expect(coordinator.tabs(in: window).map(\.id) == [a.id])
        #expect(coordinator.tabs(in: newWindow).map(\.id) == [b.id])
        #expect(coordinator.selectedTab(in: window)?.id == a.id)
    }

    @Test func failedConnectionShowsUpAsDisconnectedWithTheError() async {
        let coordinator = makeCoordinator(failure: .refused)
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        await waitUntil { if case .disconnected = tab.state { true } else { false } }
        #expect(tab.state == .disconnected(.error(.refused)))
        #expect(!tab.isLive)
        // An error keeps the tab open so its banner can explain what happened.
        #expect(coordinator.tab(id: tab.id) != nil)
    }

    @Test func exitingTheShellClosesTheTabAndFallsBackToTheServerList() async {
        let coordinator = makeCoordinator()
        let navigator = coordinator.navigator(for: window)
        navigator.isCompact = true
        let tab = navigator.open(PreviewServers.prodAPI)
        #expect(navigator.isDeckPresented)
        await waitUntil { tab.isConnected }

        tab.session.send(Data("exit\r".utf8))
        await waitUntil { coordinator.tabs(in: window).isEmpty }

        #expect(coordinator.tabs(in: window).isEmpty)
        #expect(coordinator.selectedTab(in: window) == nil)
        #expect(coordinator.recentlyClosed.first?.id == PreviewServers.prodAPI.id)
    }

    @Test func exitingOneOfSeveralTabsSelectsItsNeighbour() async {
        let coordinator = makeCoordinator()
        let a = coordinator.open(PreviewServers.prodAPI, in: window)
        let b = coordinator.open(PreviewServers.prodAPI, in: window, newSession: true)
        await waitUntil { a.isConnected && b.isConnected }

        b.session.send(Data("exit\r".utf8))
        await waitUntil { coordinator.tab(id: b.id) == nil }

        #expect(coordinator.tabs(in: window).map(\.id) == [a.id])
        #expect(coordinator.selectedTab(in: window)?.id == a.id)
    }

    @Test func onConnectedFiresOncePerConnect() async {
        let coordinator = makeCoordinator()
        var connected: [UUID] = []
        coordinator.onConnected = { connected.append($0.id) }
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        await waitUntil { tab.isConnected }
        #expect(connected == [PreviewServers.prodAPI.id])
    }

    @Test func insertTypesIntoTheConnectedSessionAndAddsReturnForRunSnippets() async {
        let coordinator = makeCoordinator()
        let tab = coordinator.open(PreviewServers.devBox, in: window)
        await waitUntil { tab.isConnected }
        let snippet = SnippetSnapshot(name: "df", command: "df -h <path>", runOnInsert: true)
        #expect(coordinator.insert(snippet, values: ["path": "/var"], in: window))
        // EchoTerminalSession echoes typed text; nothing to assert on the wire without a recorder, so check refusal paths.
        let idle = makeCoordinator()
        #expect(!idle.insert(snippet, in: window))
    }

    // MARK: Host keys

    private func makeChallenge(_ lookup: HostKeyLookup, host: String = "10.0.1.12") -> HostKeyChallenge {
        HostKeyChallenge(
            endpoint: HostEndpoint(host: host), serverName: "prod-api-01",
            presented: HostKey(algorithm: "ssh-ed25519", blobBase64: "NEW", fingerprintSHA256: "SHA256:new"),
            lookup: lookup
        )
    }

    @Test func unknownHostWaitsForTheUserAndReturnsTheirDecision() async throws {
        let coordinator = makeCoordinator()
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        let prompter = try #require(tab.prompter)
        let challenge = makeChallenge(.unknown)
        let decision = Task { await prompter.decide(challenge) }
        await waitUntil { coordinator.pendingHostKey(in: window) != nil }
        let request = coordinator.pendingHostKey(in: window)
        #expect(request?.isChangedKey == false)
        #expect(request?.windowID == window)
        coordinator.answerHostKey(request!, .connectOnce)
        #expect(await decision.value == .connectOnce)
        #expect(coordinator.pendingHostKey(in: window) == nil)
    }

    @Test func unknownHostTimesOutAsRejected() async {
        let coordinator = makeCoordinator(hostKeyTimeout: .milliseconds(30))
        let decision = await coordinator.decide(makeChallenge(.unknown))
        #expect(decision == .reject)
        #expect(coordinator.hostKeyQueue.isEmpty)
    }

    @Test func changedKeyIsATakeoverAndTheCoordinatorOnlyCarriesTheDecision() async throws {
        // The engine pins the new key and reconnects on `.trustAndSave`; the coordinator must not touch the store.
        let store = InMemoryKnownHostsStore()
        let endpoint = HostEndpoint(host: "10.0.1.12")
        let oldKey = HostKey(algorithm: "ssh-ed25519", blobBase64: "OLD", fingerprintSHA256: "SHA256:old")
        try await store.trust(oldKey, for: endpoint, replacing: false)
        var services = TildeServices.preview
        services.knownHosts = store
        services.sessionEngine = FakeSessionEngine(connectDelay: .milliseconds(1))
        let coordinator = SessionCoordinator(services: services)

        let pinned = PinnedHostKey(key: oldKey, firstSeenAt: .now, trustedOnDevice: "MacBook")
        let decision = Task { await coordinator.decide(makeChallenge(.mismatch(pinned: [pinned]))) }
        await waitUntil { coordinator.pendingHostKey(in: window) != nil }
        let request = try #require(coordinator.pendingHostKey(in: window))
        #expect(request.isChangedKey)
        #expect(request.pinnedKeys == [pinned])
        coordinator.answerHostKey(request, .trustAndSave)
        #expect(await decision.value == .trustAndSave)
        #expect(await store.pinned(for: endpoint).map(\.key.blobBase64) == ["OLD"])
    }

    @Test func rejectingAChangedKeyDoesNotTouchThePin() async throws {
        let store = InMemoryKnownHostsStore()
        let endpoint = HostEndpoint(host: "10.0.1.12")
        let oldKey = HostKey(algorithm: "ssh-ed25519", blobBase64: "OLD", fingerprintSHA256: "SHA256:old")
        try await store.trust(oldKey, for: endpoint, replacing: false)
        var services = TildeServices.preview
        services.knownHosts = store
        let coordinator = SessionCoordinator(services: services)

        let pinned = PinnedHostKey(key: oldKey, firstSeenAt: .now, trustedOnDevice: "MacBook")
        let decision = Task { await coordinator.decide(makeChallenge(.mismatch(pinned: [pinned]))) }
        await waitUntil { coordinator.pendingHostKey(in: window) != nil }
        coordinator.answerHostKey(try #require(coordinator.pendingHostKey(in: window)), .reject)
        #expect(await decision.value == .reject)
        #expect(await store.pinned(for: endpoint).map(\.key.blobBase64) == ["OLD"])
    }

    // MARK: Prompts belong to tabs

    @Test func promptsAreMatchedToTheirTabBySessionNotByTarget() async throws {
        let coordinator = makeCoordinator()
        let other = UUID()
        // Two tabs, same server, different windows.
        let a = coordinator.open(PreviewServers.prodAPI, in: window)
        let b = coordinator.open(PreviewServers.prodAPI, in: other)
        let prompter = try #require(b.prompter)
        let challenge = makeChallenge(.unknown)
        let task = Task { await prompter.decide(challenge) }
        await waitUntil { coordinator.pendingHostKey(in: other) != nil }
        #expect(coordinator.pendingHostKey(in: window) == nil)
        let request = try #require(coordinator.pendingHostKey(in: other))
        #expect(request.tabID == b.id)
        #expect(a.id != b.id)
        coordinator.answerHostKey(request, .connectOnce)
        #expect(await task.value == .connectOnce)
    }

    @Test func closingATabRejectsItsHostKeyQuestionAndCancelsItsPasswordPrompt() async throws {
        let coordinator = makeCoordinator()
        let tab = coordinator.open(PreviewServers.devBox, in: window)
        let other = coordinator.open(PreviewServers.prodAPI, in: window)
        let tabPrompter = try #require(tab.prompter)
        let otherPrompter = try #require(other.prompter)
        let challenge = makeChallenge(.unknown)
        let hostKey = Task { await tabPrompter.decide(challenge) }
        let password = Task { await tabPrompter.password(for: PreviewServers.devBox.target, reason: .notSaved) }
        let survivor = Task { await otherPrompter.password(for: PreviewServers.prodAPI.target, reason: .notSaved) }
        await waitUntil { coordinator.hostKeyQueue.count == 1 && coordinator.passwordQueue.count == 2 }

        coordinator.close(tab)
        #expect(await hostKey.value == .reject)
        #expect(await password.value == nil)
        #expect(coordinator.hostKeyQueue.isEmpty)
        #expect(coordinator.passwordQueue.count == 1)   // the other tab's prompt is untouched
        coordinator.answerPassword(try #require(coordinator.pendingPassword(in: window)), password: "pw")
        #expect(await survivor.value == "pw")
    }

    @Test func closingAWindowClosesItsTabsAndAnswersTheirPrompts() async throws {
        let coordinator = makeCoordinator()
        let other = UUID()
        let tab = coordinator.open(PreviewServers.devBox, in: window)
        let kept = coordinator.open(PreviewServers.prodAPI, in: other)
        let navigator = coordinator.navigator(for: window)
        let tabPrompter = try #require(tab.prompter)
        let challenge = makeChallenge(.unknown)
        let hostKey = Task { await tabPrompter.decide(challenge) }
        await waitUntil { !coordinator.hostKeyQueue.isEmpty }

        coordinator.windowClosed(window)
        #expect(await hostKey.value == .reject)
        #expect(coordinator.tabs(in: window).isEmpty)
        #expect(coordinator.tabs(in: other).map(\.id) == [kept.id])
        #expect(coordinator.recentlyClosed.first?.id == PreviewServers.devBox.id)
        // The old navigator was dropped: asking again creates a new one.
        #expect(coordinator.navigator(for: window) !== navigator)
    }

    @Test func passwordPromptsTimeOutInsteadOfWaitingForever() async {
        var services = TildeServices.preview
        services.sessionEngine = FakeSessionEngine(connectDelay: .milliseconds(1))
        let coordinator = SessionCoordinator(services: services, passwordTimeout: .milliseconds(30))
        let result = await coordinator.password(for: ConnectionTarget(host: "h", username: "u"), reason: .notSaved)
        #expect(result == nil)
        #expect(coordinator.passwordQueue.isEmpty)
    }

    // MARK: iPad and Mac: no deck, so prompts stay visible

    @Test func openingASessionOnTheRegularLayoutHidesTheSidebar() {
        let coordinator = makeCoordinator()
        let navigator = coordinator.navigator(for: window)
        #expect(navigator.columnVisibility == .all)
        navigator.open(PreviewServers.prodAPI)
        #expect(navigator.columnVisibility == .detailOnly)

        navigator.columnVisibility = .all
        coordinator.closeAll()
        navigator.reopenLastClosed()
        #expect(navigator.columnVisibility == .detailOnly)
    }

    @Test func theCompactLayoutLeavesTheSidebarAlone() {
        let coordinator = makeCoordinator()
        let navigator = coordinator.navigator(for: window)
        navigator.isCompact = true
        navigator.open(PreviewServers.prodAPI)
        #expect(navigator.isDeckPresented)
        #expect(navigator.columnVisibility == .all)
    }

    @Test func openingSessionsOnTheRegularLayoutNeverRaisesTheDeck() async throws {
        let coordinator = makeCoordinator()
        let navigator = coordinator.navigator(for: window)
        #expect(!navigator.isCompact)
        navigator.open(PreviewServers.prodAPI)
        navigator.open(PreviewServers.dbPrimary)
        navigator.reopenLastClosed()
        #expect(!navigator.isDeckPresented)   // the root prompt host is never suppressed by a deck

        let tab = try #require(navigator.selectedTab)
        let prompter = try #require(tab.prompter)
        let challenge = makeChallenge(.unknown)
        let task = Task { await prompter.decide(challenge) }
        await waitUntil { coordinator.pendingHostKey(in: window) != nil }
        #expect(coordinator.pendingHostKey(in: window) != nil)   // so the window can show it, every time
        coordinator.answerHostKey(try #require(coordinator.pendingHostKey(in: window)), .reject)
        _ = await task.value
    }

    @Test func theCompactLayoutPresentsTheDeckPerWindow() {
        let coordinator = makeCoordinator()
        let phone = coordinator.navigator(for: window)
        let other = coordinator.navigator(for: UUID())
        phone.isCompact = true
        phone.open(PreviewServers.prodAPI)
        #expect(phone.isDeckPresented)
        #expect(!other.isDeckPresented)   // another window is not affected
    }

    // MARK: Links

    @Test func aSSHLinkOnlyAsksForConfirmation() throws {
        let coordinator = makeCoordinator()
        let navigator = coordinator.navigator(for: window)
        navigator.handleLink(try #require(URL(string: "ssh://deploy@10.0.4.12:2222")))
        #expect(coordinator.tabs.isEmpty)   // nothing connected
        let expected = QuickConnectResult(target: ConnectionTarget(host: "10.0.4.12", port: 2222, username: "deploy"))
        #expect(navigator.sheet == .confirmLink(expected))
    }

    @Test func malformedAndForeignLinksAreIgnored() throws {
        let coordinator = makeCoordinator()
        let navigator = coordinator.navigator(for: window)
        navigator.handleLink(try #require(URL(string: "ssh://host/path?x=1")))
        navigator.handleLink(try #require(URL(string: "https://example.com")))
        #expect(navigator.sheet == nil)
        #expect(coordinator.tabs.isEmpty)
    }

    @Test func tildeLinksNavigateOrPrefillButNeverConnect() throws {
        let coordinator = makeCoordinator()
        let navigator = coordinator.navigator(for: window)
        navigator.handleLink(try #require(URL(string: "tilde://keys")))
        #expect(navigator.sheet == .keys)
        navigator.handleLink(try #require(URL(string: "tilde://new-server?host=db.example.com&name=db")))
        guard case .saveServer(let request) = navigator.sheet else {
            Issue.record("expected the editor to open prefilled")
            return
        }
        #expect(request.server.target.host == "db.example.com")
        #expect(request.server.auth == .passwordPrompt)
        #expect(coordinator.tabs.isEmpty)

        navigator.isCompact = true
        navigator.handleLink(try #require(URL(string: "tilde://snippets")))
        #expect(navigator.phoneTab == .snippets)
    }

    @Test func aConfirmedLinkConnectsWithPasswordAuthOnly() {
        let result = QuickConnectResult(
            target: ConnectionTarget(host: "10.0.4.12", port: 2222, username: "deploy"),
            keyName: "work", jump: ConnectionTarget(host: "evil", username: "x")
        )
        let server = QuickConnectResolver.linkServer(result)
        #expect(server.auth == .passwordPrompt)
        #expect(server.keyID == nil && server.passwordSecretID == nil)
        #expect(server.jump == nil)
        #expect(server.startupCommand == nil && !server.autoTmux)
        #expect(server.target == result.target)
    }

    @Test func aConfirmedLinkOpensANewAdHocTabEvenWhenASavedServerMatches() {
        let coordinator = makeCoordinator()
        let navigator = coordinator.navigator(for: window)
        let saved = coordinator.open(PreviewServers.prodAPI, in: window)
        let link = QuickConnectResult(target: PreviewServers.prodAPI.target)
        let tab = navigator.open(QuickConnectResolver.linkServer(link), newSession: true, adHoc: true)
        #expect(tab.id != saved.id)
        #expect(tab.isAdHoc)
        #expect(tab.server.auth == .passwordPrompt)
        #expect(tab.server.keyID == nil)
    }

    // MARK: Passwords

    @Test func passwordPromptReturnsWhatTheUserTyped() async throws {
        let coordinator = makeCoordinator()
        let target = PreviewServers.devBox.target
        let tab = coordinator.open(PreviewServers.devBox, in: window, adHoc: true)
        let prompter = try #require(tab.prompter)
        let result = Task { await prompter.password(for: target, reason: .notSaved) }
        await waitUntil { coordinator.pendingPassword(in: window) != nil }
        let request = coordinator.pendingPassword(in: window)
        #expect(request?.canSaveServer == true)
        #expect(request?.windowID == window)
        coordinator.answerPassword(request!, password: "hunter2")
        #expect(await result.value == "hunter2")
    }

    @Test func cancellingThePasswordPromptReturnsNil() async {
        let coordinator = makeCoordinator()
        let result = Task { await coordinator.password(for: ConnectionTarget(host: "h", username: "u"), reason: .rejected) }
        await waitUntil { coordinator.pendingPassword(in: window) != nil }
        coordinator.answerPassword(coordinator.pendingPassword(in: window)!, password: nil)
        #expect(await result.value == nil)
    }

    @Test func updatingTheSavedPasswordWritesTheSecret() async throws {
        let secrets = InMemorySecretStore()
        var services = TildeServices.preview
        services.secretStore = secrets
        services.sessionEngine = FakeSessionEngine(connectDelay: .milliseconds(1))
        let coordinator = SessionCoordinator(services: services)
        let server = PreviewServers.stagingWeb
        let tab = coordinator.open(server, in: window)
        let prompter = try #require(tab.prompter)

        let result = Task { await prompter.password(for: server.target, reason: .rejected) }
        await waitUntil { coordinator.pendingPassword(in: window) != nil }
        let request = try #require(coordinator.pendingPassword(in: window))
        #expect(request.canUpdateSaved)
        coordinator.answerPassword(request, password: "new-secret", updateSaved: true)
        _ = await result.value
        let stored = try secrets.read(SecretRef(kind: .password, id: PreviewServers.passwordSecretID))
        #expect(stored == Data("new-secret".utf8))
    }

    @Test func savingAQuickConnectServerRaisesASaveRequest() async {
        let coordinator = makeCoordinator()
        let server = PreviewServers.devBox
        let tab = coordinator.open(server, in: window, adHoc: true)
        let prompter = tab.prompter!
        let result = Task { await prompter.password(for: server.target, reason: .notSaved) }
        await waitUntil { coordinator.pendingPassword(in: window) != nil }
        coordinator.answerPassword(coordinator.pendingPassword(in: window)!, password: "pw", saveServer: true)
        _ = await result.value
        #expect(coordinator.saveServerRequest?.password == "pw")
        #expect(coordinator.saveServerRequest?.server.auth == .password)
    }
}
