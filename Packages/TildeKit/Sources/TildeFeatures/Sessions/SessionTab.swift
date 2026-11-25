import Foundation
import Observation
import TildeCore
import TildeDesign
import TildeTerminal

/// A dismissible message over a session.
public struct TabNotice: Equatable, Sendable {
    public var headline: String
    public var detail: String?
}

/// One open session, shown as a tab (iPad/Mac) or a card in the deck (iPhone).
@MainActor
@Observable
public final class SessionTab: Identifiable {
    public let id: UUID
    public let server: ServerSnapshot
    public let session: any TerminalSession
    /// The window that owns this tab. A tab moved to its own window has `windowID == id`.
    public internal(set) var windowID: UUID
    /// `true` for Quick Connect sessions that are not saved as a server.
    public let isAdHoc: Bool
    public let openedAt: Date

    public internal(set) var state: SessionState = .idle
    public internal(set) var latencyMilliseconds: Int?
    /// A multi-line paste waiting for confirmation (shown as a sheet over the session).
    public internal(set) var pasteRequest: PendingPaste?
    /// A problem to show as a dismissible banner (for example a saved password that could not be updated).
    public var notice: TabNotice?

    /// The handle on this tab's terminal (find, clear, font size, ...). One per tab, kept alive with it and passed to
    /// `TerminalSurface(controller:)`; the menu bar acts on the selected tab's controller.
    public let terminal = TerminalController()

    @ObservationIgnored var stateTask: Task<Void, Never>?
    @ObservationIgnored var latencyTask: Task<Void, Never>?

    /// Keeps the session's prompter alive for as long as the tab exists.
    @ObservationIgnored let prompter: SessionPrompter?

    init(session: any TerminalSession, windowID: UUID, isAdHoc: Bool, prompter: SessionPrompter? = nil) {
        self.prompter = prompter
        self.id = session.id
        self.server = session.server
        self.session = session
        self.windowID = windowID
        self.isAdHoc = isAdHoc
        self.openedAt = Date()
    }

    public var title: String { server.name }
    public var environment: ServerEnvironment { server.environment }
    public var tone: EnvTone { EnvTone(server.environment) }

    /// `● 23ms`-style status for the title bar and tab strip.
    public var statusKind: StatusDot.Kind {
        switch state {
        case .idle, .connecting: .unknown
        case .connected: latencyMilliseconds.map { StatusDot.Kind(latencyMilliseconds: $0) } ?? .live
        case .reconnecting: .slow
        case .disconnected(let reason):
            if case .error = reason { .unreachable } else { .unknown }
        }
    }

    /// Connecting, connected or reconnecting: the session still counts as "live".
    public var isLive: Bool {
        switch state {
        case .idle, .disconnected: false
        case .connecting, .connected, .reconnecting: true
        }
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// The terminal surface asks this before pasting text with a line break (`TerminalSurface(onConfirmPaste:)`). The
    /// surface has already decided that the mode and environment require it.
    func confirmPaste(_ request: TildeTerminal.PasteRequest) async -> Bool {
        await requestPasteConfirmation(request.text)
    }

    /// Whether typing `text` into this session should ask first: more than one non-empty line, and the paste mode
    /// (Settings > Terminal) requires it for this server's environment. A one-line snippet never asks, with or without
    /// "run on insert" (the trailing Return is not a second line).
    func snippetNeedsConfirmation(_ text: String) -> Bool {
        Self.lines(of: text).count > 1 && TildeSettings.currentPasteMode.requiresConfirmation(for: environment)
    }

    func requestPasteConfirmation(_ text: String) async -> Bool {
        let lines = Self.lines(of: text)
        return await withCheckedContinuation { continuation in
            pasteRequest?.resolve(false)
            pasteRequest = PendingPaste(
                lineCount: max(lines.count, 1),
                previewLines: Array(lines.prefix(5)),
                truncated: lines.count > 5,
                serverName: server.name,
                environment: server.environment,
                continuation: continuation
            )
        }
    }

    /// The non-empty lines of `text` (split on CR, LF or CRLF).
    static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }).map(String.init)
    }

    public func answerPaste(_ approved: Bool) {
        pasteRequest?.resolve(approved)
        pasteRequest = nil
    }
}

/// "Paste 14 lines into prod-api-01?" (the sheet's model; `TildeTerminal.PasteRequest` is what the surface hands over).
@MainActor
public final class PendingPaste: Identifiable {
    public let id = UUID()
    public let lineCount: Int
    public let previewLines: [String]
    public let truncated: Bool
    public let serverName: String
    public let environment: ServerEnvironment
    private var continuation: CheckedContinuation<Bool, Never>?

    init(lineCount: Int, previewLines: [String], truncated: Bool, serverName: String, environment: ServerEnvironment,
         continuation: CheckedContinuation<Bool, Never>) {
        self.lineCount = lineCount
        self.previewLines = previewLines
        self.truncated = truncated
        self.serverName = serverName
        self.environment = environment
        self.continuation = continuation
    }

    func resolve(_ approved: Bool) {
        continuation?.resume(returning: approved)
        continuation = nil
    }
}
