import Foundation
import TildeCore

/// A host-key question the engine is waiting on (unknown host sheet, or the changed-key takeover).
@MainActor
public final class HostKeyRequest: Identifiable {
    public nonisolated var id: UUID { challenge.id }
    public let challenge: HostKeyChallenge
    /// The window whose tab triggered the request; `nil` shows it in whichever window is frontmost.
    public let windowID: UUID?
    public let askedAt: Date

    private var continuation: CheckedContinuation<HostKeyDecision, Never>?
    var timeoutTask: Task<Void, Never>?

    init(challenge: HostKeyChallenge, windowID: UUID?, continuation: CheckedContinuation<HostKeyDecision, Never>) {
        self.challenge = challenge
        self.windowID = windowID
        self.askedAt = Date()
        self.continuation = continuation
    }

    /// `true` for the full-screen danger takeover (a pinned key does not match, or devices disagree).
    public var isChangedKey: Bool {
        switch challenge.lookup {
        case .mismatch, .conflicted: true
        case .trusted, .unknown: false
        }
    }

    /// The pinned keys the presented one is compared with (empty for an unknown host).
    public var pinnedKeys: [PinnedHostKey] {
        switch challenge.lookup {
        case .mismatch(let pinned): pinned
        case .conflicted(let candidates): candidates
        case .trusted, .unknown: []
        }
    }

    func resolve(_ decision: HostKeyDecision) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(returning: decision)
        continuation = nil
    }
}

/// A password question (never saved, unless the user asks).
@MainActor
public final class PasswordRequest: Identifiable {
    public let id = UUID()
    public let target: ConnectionTarget
    public let reason: PromptReason
    public let serverName: String
    public let windowID: UUID?
    /// Offer "Save server" (a Quick Connect session that is not saved yet).
    public let canSaveServer: Bool
    /// Offer "Update saved password" (the saved password was rejected).
    public let canUpdateSaved: Bool
    private var continuation: CheckedContinuation<String?, Never>?

    init(target: ConnectionTarget, reason: PromptReason, serverName: String, windowID: UUID?,
         canSaveServer: Bool, canUpdateSaved: Bool, continuation: CheckedContinuation<String?, Never>) {
        self.target = target
        self.reason = reason
        self.serverName = serverName
        self.windowID = windowID
        self.canSaveServer = canSaveServer
        self.canUpdateSaved = canUpdateSaved
        self.continuation = continuation
    }

    var headline: String {
        switch reason {
        case .notSaved: "Password for \(target.username)@\(target.host)"
        case .rejected: "Password rejected"
        case .secretNotSynced: "Waiting for iCloud Keychain"
        }
    }

    var detail: String {
        switch reason {
        case .notSaved: "Enter the password for this session. It is not stored."
        case .rejected: "\(target.username)@\(target.host) did not accept the password. Try again."
        case .secretNotSynced: "The saved password has not arrived on this device yet. Enter it once for this session."
        }
    }

    func resolve(_ password: String?) {
        continuation?.resume(returning: password)
        continuation = nil
    }
}

/// "Save as server…" after a Quick Connect: opens the editor prefilled.
public struct SaveServerRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var server: ServerSnapshot
    /// The password the user typed, to store with the new server.
    public var password: String?
}
