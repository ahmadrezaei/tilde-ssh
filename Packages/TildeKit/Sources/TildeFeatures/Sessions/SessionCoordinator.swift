import Foundation
import Observation
import TildeCore

/// Owns every open session (tabs), creates them through `SessionEngine.makeSession`, and answers the engine's
/// questions: it is the app's `HostKeyPrompter` and `PasswordPrompter`.
///
/// Tabs belong to a window (`windowID`): each iPad/Mac window shows its own tab strip, and a tab moved to a new
/// window gets its own id. iPhone has a single window. Views observe this class directly (`@Observable`).
@MainActor
@Observable
public final class SessionCoordinator: HostKeyPrompter, PasswordPrompter {
    public let services: TildeServices
    public let reachability: ReachabilityMonitor

    public private(set) var tabs: [SessionTab] = []
    /// Selected tab per window.
    public private(set) var selectedTabIDs: [UUID: UUID] = [:]
    /// Host-key questions in arrival order; the UI shows the first one that belongs to its window.
    public private(set) var hostKeyQueue: [HostKeyRequest] = []
    public private(set) var passwordQueue: [PasswordRequest] = []
    /// iPhone: whether the full-screen session deck is up.
    public var isDeckPresented = false
    /// Set after "Save server" on a Quick Connect password prompt; the root view opens the editor.
    public var saveServerRequest: SaveServerRequest?
    /// Most recently closed first; "Reopen last closed session" (Cmd-Shift-T).
    public private(set) var recentlyClosed: [ServerSnapshot] = []

    /// Called when a session reaches `connected` (the app throttles and stores `Server.lastConnectedAt`).
    public var onConnected: (@MainActor (ServerSnapshot) -> Void)?

    public static let defaultHostKeyTimeout: Duration = .seconds(120)
    private let hostKeyTimeout: Duration

    public init(services: TildeServices, hostKeyTimeout: Duration = SessionCoordinator.defaultHostKeyTimeout) {
        self.services = services
        self.hostKeyTimeout = hostKeyTimeout
        self.reachability = ReachabilityMonitor(prober: services.reachability)
    }

    // MARK: Queries

    public func tabs(in window: UUID) -> [SessionTab] { tabs.filter { $0.windowID == window } }

    public func selectedTab(in window: UUID) -> SessionTab? {
        let inWindow = tabs(in: window)
        if let id = selectedTabIDs[window], let tab = inWindow.first(where: { $0.id == id }) { return tab }
        return inWindow.last
    }

    public func tab(id: UUID) -> SessionTab? { tabs.first { $0.id == id } }

    public var liveTabs: [SessionTab] { tabs.filter(\.isLive) }
    public var hasTabs: Bool { !tabs.isEmpty }

    /// `true` when some session for this saved server is live (drives the pulsing dot in the list).
    public func isLive(serverID: UUID) -> Bool { tabs.contains { $0.server.id == serverID && $0.isLive } }

    // MARK: Opening and closing

    /// Opens a session for `server`, or focuses its existing one in this window.
    /// - Parameter newSession: always create a new tab ("New session", leading swipe).
    @discardableResult
    public func open(_ server: ServerSnapshot, in window: UUID, newSession: Bool = false, adHoc: Bool = false) -> SessionTab {
        if !newSession, let existing = tabs(in: window).first(where: { Self.sameServer($0.server, server) }) {
            select(existing)
            return existing
        }
        let request = SessionRequest(
            server: server,
            pty: PTYConfig(term: server.termType, cols: 80, rows: 24, env: server.envVars),
            connectTimeout: .seconds(TildeSettings.currentConnectTimeout)
        )
        let session = services.sessionEngine.makeSession(
            request,
            credentials: services.credentials,
            knownHosts: services.knownHosts,
            hostKeyPrompter: self,
            passwordPrompter: self
        )
        let tab = SessionTab(session: session, windowID: window, isAdHoc: adHoc)
        tabs.append(tab)
        select(tab)
        observe(tab)
        Task { await session.connect() }
        return tab
    }

    public func select(_ tab: SessionTab) { selectedTabIDs[tab.windowID] = tab.id }

    public func select(index: Int, in window: UUID) {
        let inWindow = tabs(in: window)
        guard !inWindow.isEmpty else { return }
        // Cmd-9 always goes to the last tab (Terminal.app / browser convention).
        let tab = index >= 9 ? inWindow[inWindow.count - 1] : inWindow[min(max(index - 1, 0), inWindow.count - 1)]
        select(tab)
    }

    public func selectNext(in window: UUID) { step(1, in: window) }
    public func selectPrevious(in window: UUID) { step(-1, in: window) }

    private func step(_ delta: Int, in window: UUID) {
        let inWindow = tabs(in: window)
        guard inWindow.count > 1, let current = selectedTab(in: window), let index = inWindow.firstIndex(where: { $0.id == current.id }) else { return }
        select(inWindow[(index + delta + inWindow.count) % inWindow.count])
    }

    public func close(_ tab: SessionTab) {
        tab.stateTask?.cancel()
        tab.latencyTask?.cancel()
        tab.pasteRequest?.resolve(false)
        let session = tab.session
        Task { await session.disconnect() }

        let window = tab.windowID
        let wasSelected = selectedTab(in: window)?.id == tab.id
        let siblings = tabs(in: window)
        let index = siblings.firstIndex(where: { $0.id == tab.id })
        tabs.removeAll { $0.id == tab.id }
        recentlyClosed.insert(tab.server, at: 0)
        if recentlyClosed.count > 10 { recentlyClosed.removeLast() }

        let remaining = tabs(in: window)
        if wasSelected {
            if let index, !remaining.isEmpty { select(remaining[min(index, remaining.count - 1)]) } else { selectedTabIDs[window] = nil }
        }
        if tabs.isEmpty { isDeckPresented = false }
    }

    public func closeSelected(in window: UUID) {
        if let tab = selectedTab(in: window) { close(tab) }
    }

    public func closeAll() {
        for tab in tabs { close(tab) }
    }

    @discardableResult
    public func reopenLastClosed(in window: UUID) -> SessionTab? {
        guard !recentlyClosed.isEmpty else { return nil }
        let server = recentlyClosed.removeFirst()
        return open(server, in: window, newSession: true)
    }

    public func reconnect(_ tab: SessionTab) {
        let session = tab.session
        Task { await session.reconnect() }
    }

    /// "Move Tab to New Window": the tab gets a window id of its own (`SessionWindow` keys on it).
    @discardableResult
    public func moveToOwnWindow(_ tab: SessionTab) -> UUID {
        let old = tab.windowID
        tab.windowID = tab.id
        select(tab)
        if selectedTabIDs[old] == tab.id { selectedTabIDs[old] = nil }
        return tab.id
    }

    // MARK: Snippets

    /// Types a snippet into the window's active session (and presses Return for run-on-insert snippets).
    /// Goes through the paste guard, so a multi-line snippet to a PROD server asks first.
    @discardableResult
    public func insert(_ snippet: SnippetSnapshot, values: [String: String] = [:], in window: UUID) -> Bool {
        guard let tab = selectedTab(in: window), tab.isConnected else { return false }
        var text = SnippetTemplate.fill(snippet.command, values: values)
        if snippet.runOnInsert { text += "\r" }
        tab.terminalIO.send(Data(text.utf8))
        return true
    }

    // MARK: Observing sessions

    private func observe(_ tab: SessionTab) {
        let session = tab.session
        tab.stateTask = Task { [weak self, weak tab] in
            for await state in session.states {
                guard let self, let tab else { return }
                self.apply(state, to: tab)
            }
        }
        tab.latencyTask = Task { [weak tab] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let tab else { return }
                guard tab.isConnected, let latency = await session.latency() else { continue }
                tab.latencyMilliseconds = ReachabilityMonitor.milliseconds(latency)
            }
        }
    }

    func apply(_ state: SessionState, to tab: SessionTab) {
        tab.state = state
        switch state {
        case .connected(let info):
            tab.latencyMilliseconds = info.latency.map(ReachabilityMonitor.milliseconds)
            onConnected?(tab.server)
        case .disconnected, .idle, .connecting, .reconnecting:
            break
        }
    }

    // MARK: Host keys (HostKeyPrompter)

    public func pendingHostKey(in window: UUID) -> HostKeyRequest? {
        hostKeyQueue.first { $0.windowID == nil || $0.windowID == window }
    }

    public func decide(_ challenge: HostKeyChallenge) async -> HostKeyDecision {
        let window = tab(matching: challenge.endpoint)?.windowID
        let decision = await withCheckedContinuation { (continuation: CheckedContinuation<HostKeyDecision, Never>) in
            let request = HostKeyRequest(challenge: challenge, windowID: window, continuation: continuation)
            hostKeyQueue.append(request)
            // An unknown host never auto-trusts: after 120 s the handshake gives up.
            request.timeoutTask = Task { [weak self, weak request] in
                try? await Task.sleep(for: self?.hostKeyTimeout ?? Self.defaultHostKeyTimeout)
                guard !Task.isCancelled, let self, let request else { return }
                self.answerHostKey(request, .reject)
            }
        }
        if decision == .trustAndSave {
            await pinAfterChangedKey(challenge)
        }
        return decision
    }

    /// Resolves the question shown in the sheet or takeover.
    public func answerHostKey(_ request: HostKeyRequest, _ decision: HostKeyDecision) {
        guard hostKeyQueue.contains(where: { $0.id == request.id }) else { return }
        hostKeyQueue.removeAll { $0.id == request.id }
        request.resolve(decision)
    }

    /// For a changed key the engine has already aborted, so "Hold to trust new key" must replace the pin and then
    /// reconnect. The pin write is idempotent (`replacing: true`), so it is safe if the engine also writes it. If
    /// the engine does not reconnect on its own, the tab is reconnected shortly after.
    private func pinAfterChangedKey(_ challenge: HostKeyChallenge) async {
        switch challenge.lookup {
        case .mismatch, .conflicted:
            try? await services.knownHosts.trust(challenge.presented, for: challenge.endpoint, replacing: true)
            guard let tab = tab(matching: challenge.endpoint) else { return }
            Task { [weak self, weak tab] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, let tab else { return }
                if case .disconnected(.error(.hostKeyMismatch)) = tab.state { self.reconnect(tab) }
            }
        case .trusted, .unknown:
            break
        }
    }

    private func tab(matching endpoint: HostEndpoint) -> SessionTab? {
        func matches(_ target: ConnectionTarget) -> Bool {
            target.host.caseInsensitiveCompare(endpoint.host) == .orderedSame && target.port == endpoint.port
        }
        let candidates = tabs.filter { matches($0.server.target) || ($0.server.jump.map { matches($0.target) } ?? false) }
        return candidates.first { !$0.isConnected } ?? candidates.first
    }

    // MARK: Passwords (PasswordPrompter)

    public func pendingPassword(in window: UUID) -> PasswordRequest? {
        passwordQueue.first { $0.windowID == nil || $0.windowID == window }
    }

    public func password(for target: ConnectionTarget, reason: PromptReason) async -> String? {
        let owner = tabs.first { $0.server.target == target || $0.server.jump?.target == target }
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            passwordQueue.append(PasswordRequest(
                target: target, reason: reason,
                serverName: owner?.server.name ?? target.host,
                windowID: owner?.windowID,
                canSaveServer: owner?.isAdHoc ?? false,
                canUpdateSaved: owner.map { $0.server.auth == .password && $0.server.passwordSecretID != nil } ?? false,
                continuation: continuation
            ))
        }
    }

    /// Resolves the password sheet. `nil` cancels.
    public func answerPassword(_ request: PasswordRequest, password: String?, saveServer: Bool = false, updateSaved: Bool = false) {
        guard passwordQueue.contains(where: { $0.id == request.id }) else { return }
        passwordQueue.removeAll { $0.id == request.id }
        if let password {
            let owner = tabs.first { $0.server.target == request.target || $0.server.jump?.target == request.target }
            if updateSaved, let owner, let secretID = owner.server.passwordSecretID {
                try? services.secretStore.write(
                    Data(password.utf8), for: SecretRef(kind: .password, id: secretID),
                    label: "Tilde: \(request.target.username)@\(request.target.host)", synchronizable: true
                )
            }
            if saveServer, let owner {
                var server = owner.server
                server.auth = .password
                saveServerRequest = SaveServerRequest(server: server, password: password)
            }
        }
        request.resolve(password)
    }

    // MARK: Helpers

    /// Two snapshots are the same server for "focus the existing session": same saved id, or (Quick Connect) same target.
    static func sameServer(_ a: ServerSnapshot, _ b: ServerSnapshot) -> Bool {
        a.id == b.id || a.target == b.target
    }
}
