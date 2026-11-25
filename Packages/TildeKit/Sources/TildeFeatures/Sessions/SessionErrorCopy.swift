import Foundation
import TildeCore

/// An action a session banner can offer.
enum SessionErrorAction: Equatable {
    case retry, edit, copyPublicKey, installKey, tryAgain, copyDetails, enterOnce, openSyncSettings, close

    var title: String {
        switch self {
        case .retry: "Retry"
        case .edit: "Edit"
        case .copyPublicKey: "Copy public key"
        case .installKey: "Install key…"
        case .tryAgain: "Try again"
        case .copyDetails: "Copy details"
        case .enterOnce: "Enter once"
        case .openSyncSettings: "Open Settings › Sync"
        case .close: "Close tab"
        }
    }
}

/// Banner copy for a failed session (design section 4.9): a short headline, a mono detail line, 1-3 actions.
struct SessionErrorPresentation: Equatable {
    var headline: String
    var detail: String?
    var actions: [SessionErrorAction]
}

enum SessionErrorCopy {
    /// - Parameter keyName: the name of the key the server uses, for the "rejected" message.
    static func present(_ error: SessionError, server: ServerSnapshot, keyName: String? = nil) -> SessionErrorPresentation {
        let target = server.target
        switch error {
        case .dnsFailure(let host):
            return .init(headline: "Can't resolve \(host)", detail: "Check VPN or DNS.", actions: [.retry, .edit])
        case .refused:
            return .init(headline: "Connection refused · \(target.hostPort)", detail: "sshd not running or wrong port.", actions: [.retry, .edit])
        case .timeout(let seconds):
            return .init(headline: "No response after \(seconds)s · \(target.hostPort)", detail: "Firewall / security group / VPN?", actions: [.retry, .edit])
        case .networkLost:
            return .init(headline: "Network connection lost", detail: "The connection dropped and could not be re-established.", actions: [.retry, .close])
        case .hostKeyMismatch:
            return .init(headline: "Host key changed · connection aborted", detail: "No credentials were sent to \(target.hostPort).", actions: [.retry, .edit])
        case .hostKeyRejected:
            return .init(headline: "Host key not trusted", detail: "Cancelled before any credentials were sent.", actions: [.retry, .edit])
        case .authFailed(let method, let allows):
            return authFailed(method: method, allows: allows, server: server, keyName: keyName)
        case .secretUnavailable(let ref):
            let what = ref.kind == .password ? "Password" : "Key"
            return .init(headline: "\(what) not on this device yet",
                         detail: "Waiting for iCloud Keychain to deliver it.",
                         actions: ref.kind == .password ? [.enterOnce, .openSyncSettings] : [.retry, .openSyncSettings])
        case .noCommonAlgorithm(let kind, let offered):
            let list = offered.isEmpty ? "none" : offered.joined(separator: ", ")
            return .init(headline: "No common algorithm (\(kind))", detail: "Server offers: \(list)", actions: [.copyDetails])
        case .channelFailed(let message):
            return .init(headline: "Couldn't open a shell", detail: message, actions: [.retry, .copyDetails])
        case .underlying(let message):
            return .init(headline: "Connection failed", detail: message, actions: [.retry, .copyDetails])
        }
    }

    /// Text for "Copy details".
    static func details(for error: SessionError, server: ServerSnapshot) -> String {
        let p = present(error, server: server)
        return [p.headline, p.detail].compactMap { $0 }.joined(separator: "\n")
    }

    private static func authFailed(method: String, allows: [String], server: ServerSnapshot, keyName: String?) -> SessionErrorPresentation {
        let lowered = allows.map { $0.lowercased() }
        let onlyInteractive = !lowered.isEmpty && lowered.contains("keyboard-interactive")
            && !lowered.contains("publickey") && !lowered.contains("password")
        if onlyInteractive {
            return .init(headline: "Server only allows keyboard-interactive", detail: "2FA/PAM prompts arrive in v1.1.", actions: [.edit])
        }
        if method.lowercased().contains("publickey") || method.lowercased().contains("key") {
            let name = keyName.map { "Key \($0)" } ?? "The key"
            let accepts = allows.isEmpty ? "" : " Server accepts: \(allows.joined(separator: ", "))."
            return .init(headline: "Permission denied (publickey)", detail: "\(name) was rejected.\(accepts)",
                         actions: [.copyPublicKey, .installKey, .edit])
        }
        return .init(headline: "Permission denied (password)", detail: nil, actions: [.tryAgain, .edit])
    }
}

/// Human text for the connecting phases (overlay while `SessionState.connecting`).
extension ConnectPhase {
    var title: String {
        switch self {
        case .resolving: "Resolving host"
        case .tcp: "Opening connection"
        case .jumpHost: "Connecting through jump host"
        case .handshake: "Negotiating encryption"
        case .hostKey: "Verifying host key"
        case .authenticating: "Authenticating"
        case .openingShell: "Opening shell"
        }
    }
}
