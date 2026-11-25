import Foundation
import TildeCore

/// A screen a `tilde://` link can open.
public enum TildeURLDestination: String, Equatable, Sendable {
    case servers, keys, snippets, settings
}

/// What an incoming `ssh://` or `tilde://` link asks for.
///
/// Links must never connect on their own: anyone can put one on a web page. The app should show the target
/// (for example in Quick Connect, prefilled) and wait for the user to confirm.
public enum TildeURLAction: Equatable, Sendable {
    /// Connect to a target. From `ssh://user@host:port` or `tilde://connect?host=...`.
    case connect(QuickConnectResult)
    /// Open the new-server editor prefilled. From `tilde://new-server?host=...&name=...`.
    case newServer(QuickConnectResult, name: String?)
    /// Show a screen. From `tilde://servers`, `tilde://keys`, `tilde://snippets`, `tilde://settings`.
    case show(TildeURLDestination)
}

/// Parses links handed to `onOpenURL`.
///
/// Grammar:
/// - `ssh://[user@]host[:port]`: parsed by the app's `QuickConnectParsing`.
/// - `tilde://connect?host=H[&port=P][&user=U]` and `tilde://connect/user@host:port`.
/// - `tilde://new-server?host=H[&port=P][&user=U][&name=N]`.
/// - `tilde://servers`, `tilde://keys`, `tilde://snippets`, `tilde://settings`.
///
/// Hosts are validated: no whitespace or control characters, no leading `-`, and ports must be 1 to 65535.
public struct TildeURLParser: Sendable {
    private let quickConnect: any QuickConnectParsing
    private let defaultUsername: String

    /// - Parameters:
    ///   - quickConnect: usually `services.quickConnect`.
    ///   - defaultUsername: used by `tilde://` links that omit a user.
    public init(quickConnect: any QuickConnectParsing, defaultUsername: String = "root") {
        self.quickConnect = quickConnect
        self.defaultUsername = defaultUsername
    }

    /// Returns the requested action, or `nil` if the link is not one Tilde understands.
    public func parse(_ url: URL) -> TildeURLAction? {
        switch url.scheme?.lowercased() {
        case "ssh":
            guard let result = quickConnect.parse(url.absoluteString), Self.isValid(result.target) else { return nil }
            return .connect(result)
        case "tilde":
            return parseTilde(url)
        default:
            return nil
        }
    }

    private func parseTilde(_ url: URL) -> TildeURLAction? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let verb = components.host?.lowercased() else {
            return nil
        }
        if let destination = TildeURLDestination(rawValue: verb) { return .show(destination) }

        switch verb {
        case "connect":
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty {
                guard let result = quickConnect.parse(path), Self.isValid(result.target) else { return nil }
                return .connect(result)
            }
            return target(from: components).map { .connect($0) }
        case "new-server":
            let name = components.queryItems?.first(where: { $0.name == "name" })?.value
            return target(from: components).map { .newServer($0, name: name?.isEmpty == false ? name : nil) }
        default:
            return nil
        }
    }

    private func target(from components: URLComponents) -> QuickConnectResult? {
        func value(_ name: String) -> String? { components.queryItems?.first(where: { $0.name == name })?.value }
        guard let host = value("host"), !host.isEmpty else { return nil }
        let port = value("port").flatMap(Int.init) ?? 22
        let user = value("user").flatMap { $0.isEmpty ? nil : $0 } ?? defaultUsername
        let target = ConnectionTarget(host: host, port: port, username: user)
        return Self.isValid(target) ? QuickConnectResult(target: target) : nil
    }

    /// Rejects hosts and users that could be mistaken for options or that contain unprintable characters.
    static func isValid(_ target: ConnectionTarget) -> Bool {
        guard (1...65535).contains(target.port) else { return false }
        guard !target.host.isEmpty, !target.host.hasPrefix("-"), !target.username.hasPrefix("-") else { return false }
        let bad = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return target.host.rangeOfCharacter(from: bad) == nil && target.username.rangeOfCharacter(from: bad) == nil
    }
}
