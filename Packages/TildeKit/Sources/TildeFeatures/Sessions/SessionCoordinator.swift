import Foundation
import Observation
import Security
import TildeCore
import TildeSecurity

/// A tab that was just closed: which server, in which window, and how its session ended.
public struct ClosedSession: Equatable, Sendable {
    /// Distinguishes two closures that look alike (the same server closed the same way twice).
    public let id = UUID()
    public let server: ServerSnapshot
    public let windowID: UUID
    /// `.userClosed` when the tab was closed while its session was still running.
    public let reason: SessionEndReason

    public init(server: ServerSnapshot, windowID: UUID, reason: SessionEndReason) {
        self.server = server
        self.windowID = windowID
        self.reason = reason
    }
}

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
    /// Set after "Save server" on a Quick Connect password prompt; the root view opens the editor.
    public var saveServerRequest: SaveServerRequest?
    /// Most recently closed first; "Reopen last closed session" (Cmd-Shift-T).
    public private(set) var recentlyClosed: [ServerSnapshot] = []
    /// The tab that was closed last, with the window it belonged to and why its session ended (the Mac start page
    /// reads it for "prod-api-01: shell exited").
    public private(set) var lastClosure: ClosedSession?

    /// Called when a session reaches `connected` (the app throttles and stores `Server.lastConnectedAt`).
    public var onConnected: (@MainActor (ServerSnapshot) -> Void)?

    public static let defaultHostKeyTimeout: Duration = .seconds(120)
    public static let defaultPasswordTimeout: Duration = .seconds(300)
    private let hostKeyTimeout: Duration
    private let passwordTimeout: Duration
    /// One navigator per window, created on first use and dropped when the window closes.
    @ObservationIgnored private var navigators: [UUID: AppNavigator] = [:]

    public init(
        services: TildeServices,
        hostKeyTimeout: Duration = SessionCoordinator.defaultHostKeyTimeout,
        passwordTimeout: Duration = SessionCoordinator.defaultPasswordTimeout
    ) {
        self.services = services
        self.hostKeyTimeout = hostKeyTimeout
        self.passwordTimeout = passwordTimeout
        self.reachability = ReachabilityMonitor(prober: services.reachability)
    }

    // MARK: Windows

    /// The navigator of a window (UI routing: sheets, deck, iPhone tab), created on first use.
    public func navigator(for window: UUID) -> AppNavigator {
        if let existing = navigators[window] { return existing }
        let navigator = AppNavigator(coordinator: self, windowID: window)
        navigators[window] = navigator
        return navigator
    }

    /// A window went away: close its tabs (which answers their pending prompts) and forget its navigator.
    public func windowClosed(_ window: UUID) {
        for tab in tabs(in: window) { close(tab) }
        selectedTabIDs[window] = nil
        navigators[window] = nil
        for request in hostKeyQueue where request.windowID == window { answerHostKey(request, .reject) }
        for request in passwordQueue where request.windowID == window { answerPassword(request, password: nil) }
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
        let prompter = SessionPrompter(coordinator: self)
        let session = services.sessionEngine.makeSession(
            request,
            credentials: services.credentials,
            knownHosts: services.knownHosts,
            hostKeyPrompter: prompter,
            passwordPrompter: prompter
        )
        prompter.tabID = session.id
        let tab = SessionTab(session: session, windowID: window, isAdHoc: adHoc, prompter: prompter)
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
        // A closed tab can no longer answer: release the engine, which is waiting on its questions.
        for request in hostKeyQueue where request.tabID == tab.id { answerHostKey(request, .reject) }
        for request in passwordQueue where request.tabID == tab.id { answerPassword(request, password: nil) }
        let session = tab.session
        Task { await session.disconnect() }

        let window = tab.windowID
        let wasSelected = selectedTab(in: window)?.id == tab.id
        let siblings = tabs(in: window)
        let index = siblings.firstIndex(where: { $0.id == tab.id })
        tabs.removeAll { $0.id == tab.id }
        recentlyClosed.insert(tab.server, at: 0)
        let reason: SessionEndReason
        if case .disconnected(let ended) = tab.state { reason = ended } else { reason = .userClosed }
        lastClosure = ClosedSession(server: tab.server, windowID: window, reason: reason)
        if recentlyClosed.count > 10 { recentlyClosed.removeLast() }

        let remaining = tabs(in: window)
        if wasSelected {
            if let index, !remaining.isEmpty { select(remaining[min(index, remaining.count - 1)]) } else { selectedTabIDs[window] = nil }
        }
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
    ///
    /// A one-line snippet is the user's explicit action and goes straight to the session. A multi-line one asks first
    /// when the paste rules (Settings > Terminal, always for PROD in the default mode) say so, through the same sheet
    /// the terminal uses for pastes.
    @discardableResult
    public func insert(_ snippet: SnippetSnapshot, values: [String: String] = [:], in window: UUID) -> Bool {
        guard let tab = selectedTab(in: window), tab.isConnected else { return false }
        var text = SnippetTemplate.fill(snippet.command, values: values)
        let needsConfirmation = tab.snippetNeedsConfirmation(text)
        if snippet.runOnInsert { text += "\r" }
        let bytes = Data(text.utf8)
        guard needsConfirmation else {
            tab.session.send(bytes)
            return true
        }
        Task { [weak tab] in
            guard let tab, await tab.requestPasteConfirmation(text), tab.isConnected else { return }
            tab.session.send(bytes)
        }
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

    /// For prompts that do not belong to a tab (for example "Test connection" in the server editor).
    public func decide(_ challenge: HostKeyChallenge) async -> HostKeyDecision {
        await decide(challenge, tabID: nil)
    }

    func decide(_ challenge: HostKeyChallenge, tabID: UUID?) async -> HostKeyDecision {
        let tab = tabID.flatMap(self.tab(id:))
        // The engine pins the key (`trust`, `replacing: true` after a change) and reconnects on `.trustAndSave`
        // itself; the coordinator only carries the user's decision back.
        return await withCheckedContinuation { (continuation: CheckedContinuation<HostKeyDecision, Never>) in
            let request = HostKeyRequest(challenge: challenge, tabID: tabID, windowID: tab?.windowID, continuation: continuation)
            hostKeyQueue.append(request)
            // An unknown host never auto-trusts: after 120 s the handshake gives up.
            request.timeoutTask = Task { [weak self, weak request] in
                try? await Task.sleep(for: self?.hostKeyTimeout ?? Self.defaultHostKeyTimeout)
                guard !Task.isCancelled, let self, let request else { return }
                self.answerHostKey(request, .reject)
            }
        }
    }

    /// Resolves the question shown in the sheet or takeover.
    public func answerHostKey(_ request: HostKeyRequest, _ decision: HostKeyDecision) {
        guard hostKeyQueue.contains(where: { $0.id == request.id }) else { return }
        hostKeyQueue.removeAll { $0.id == request.id }
        request.resolve(decision)
    }

    // MARK: Passwords (PasswordPrompter)

    public func pendingPassword(in window: UUID) -> PasswordRequest? {
        passwordQueue.first { $0.windowID == nil || $0.windowID == window }
    }

    /// For prompts that do not belong to a tab (for example "Test connection" in the server editor).
    public func password(for target: ConnectionTarget, reason: PromptReason) async -> String? {
        await password(for: target, reason: reason, tabID: nil)
    }

    func password(for target: ConnectionTarget, reason: PromptReason, tabID: UUID?) async -> String? {
        let owner = tabID.flatMap(self.tab(id:))
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let request = PasswordRequest(
                target: target, reason: reason,
                serverName: owner?.server.name ?? target.host,
                tabID: tabID,
                windowID: owner?.windowID,
                canSaveServer: owner?.isAdHoc ?? false,
                canUpdateSaved: owner.map { $0.server.auth == .password && $0.server.passwordSecretID != nil } ?? false,
                continuation: continuation
            )
            passwordQueue.append(request)
            // Nobody should be left waiting forever on a prompt that is never answered.
            request.timeoutTask = Task { [weak self, weak request] in
                try? await Task.sleep(for: self?.passwordTimeout ?? Self.defaultPasswordTimeout)
                guard !Task.isCancelled, let self, let request else { return }
                self.answerPassword(request, password: nil)
            }
        }
    }

    /// Resolves the password sheet. `nil` cancels.
    public func answerPassword(_ request: PasswordRequest, password: String?, saveServer: Bool = false, updateSaved: Bool = false) {
        guard passwordQueue.contains(where: { $0.id == request.id }) else { return }
        passwordQueue.removeAll { $0.id == request.id }
        if let password, let owner = request.tabID.flatMap(tab(id:)) {
            if updateSaved, let secretID = owner.server.passwordSecretID {
                do {
                    try services.secretStore.write(
                        Data(password.utf8), for: SecretRef(kind: .password, id: secretID),
                        label: "Tilde: \(request.target.username)@\(request.target.host)", synchronizable: true
                    )
                } catch {
                    owner.notice = TabNotice(
                        headline: "Couldn't update the saved password in the Keychain (OSStatus \(Self.status(of: error))).",
                        detail: "This connection uses the password you typed, but the saved one is unchanged."
                    )
                }
            }
            if saveServer {
                var server = owner.server
                server.auth = .password
                saveServerRequest = SaveServerRequest(server: server, password: password)
            }
        }
        request.resolve(password)
    }

    // MARK: Helpers

    static func status(of error: any Error) -> OSStatus {
        (error as? KeychainError)?.status ?? errSecInternalError
    }

    /// Two snapshots are the same server for "focus the existing session": same saved id, or (Quick Connect) same target.
    static func sameServer(_ a: ServerSnapshot, _ b: ServerSnapshot) -> Bool {
        a.id == b.id || a.target == b.target
    }
}
