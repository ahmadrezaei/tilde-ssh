import Foundation
import TildeCore

/// A screen a `tilde://` link can open.
public enum TildeURLDestination: String, Equatable, Sendable {
    case servers, keys, snippets, settings
}

/// What an incoming `ssh://` or `tilde://` link asks for.
///
/// **A link must never connect on its own.** Anyone can put one on a web page or in a message. The UI has to show
/// the target (for example by prefilling Quick Connect) and wait for the user to confirm before any connection,
/// credential prompt or key use happens.
///
/// The `QuickConnectResult` values produced from links only ever carry a host, port and user: `jump` and
/// `keyName` are always `nil`, so a link cannot route a connection through a host of its choosing or pick which
/// key gets offered.
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
/// Grammar (anything else is rejected):
/// - `ssh://[user@]host[:port]` with an empty path (or `/`), no query, no fragment and no password.
/// - `tilde://connect?host=H[&port=P][&user=U]` and `tilde://connect/[user@]host[:port]`.
/// - `tilde://new-server?host=H[&port=P][&user=U][&name=N]`.
/// - `tilde://servers`, `tilde://keys`, `tilde://snippets`, `tilde://settings`.
///
/// Links are parsed structurally with `URLComponents`; their text is never passed to the free-text Quick Connect
/// parser, which also understands `-J` and `-i`. Hosts may contain only letters, digits and `. - _ :`
/// (IPv6 brackets are stripped), may not start with `-`, and ports must be numbers from 1 to 65535. A `port`
/// that is present but not a number rejects the link instead of falling back to 22. Unknown query items
/// (`jump`, `key`, ...) are ignored.
public struct TildeURLParser: Sendable {
    private let defaultUsername: String

    /// - Parameters:
    ///   - quickConnect: accepted for source compatibility and not used: link text is never given to the
    ///     free-text parser.
    ///   - defaultUsername: used by links that omit a user.
    public init(quickConnect: (any QuickConnectParsing)? = nil, defaultUsername: String = "root") {
        self.defaultUsername = defaultUsername
    }

    /// Returns the requested action, or `nil` if the link is not one Tilde understands or is malformed.
    public func parse(_ url: URL) -> TildeURLAction? {
        switch url.scheme?.lowercased() {
        case "ssh":
            return parseSSH(url).map { .connect($0) }
        case "tilde":
            return parseTilde(url)
        default:
            return nil
        }
    }

    // MARK: ssh://

    private func parseSSH(_ url: URL) -> QuickConnectResult? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host
        else { return nil }

        // `URLComponents.port` hides a malformed port, so read the authority's port text as well.
        let port: Int
        if let text = Self.portText(in: url.absoluteString) {
            guard let parsed = Int(text), parsed == components.port else { return nil }
            port = parsed
        } else {
            port = 22
        }
        return makeResult(host: host, port: port, user: components.user)
    }

    /// The text after the last `:` of the authority's host part, if there is a port. `nil` when there is none.
    static func portText(in absoluteString: String) -> String? {
        guard let schemeEnd = absoluteString.range(of: "://") else { return nil }
        var authority = absoluteString[schemeEnd.upperBound...]
        if let end = authority.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            authority = authority[..<end]
        }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let rest = authority[authority.index(after: close)...]
            return rest.hasPrefix(":") ? String(rest.dropFirst()) : nil
        }
        // A bare IPv6 address has several colons and no port; `host:port` has exactly one.
        guard authority.filter({ $0 == ":" }).count == 1, let colon = authority.firstIndex(of: ":") else { return nil }
        return String(authority[authority.index(after: colon)...])
    }

    // MARK: tilde://

    private func parseTilde(_ url: URL) -> TildeURLAction? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let verb = components.host?.lowercased()
        else { return nil }
        if let destination = TildeURLDestination(rawValue: verb) { return .show(destination) }

        switch verb {
        case "connect":
            let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty {
                guard let target = URL(string: "ssh://" + path) else { return nil }
                return parseSSH(target).map { .connect($0) }
            }
            return target(from: components).map { .connect($0) }
        case "new-server":
            guard let result = target(from: components) else { return nil }
            let name = singleValue("name", in: components).flatMap { $0.isEmpty ? nil : $0 }
            return .newServer(result, name: name)
        default:
            return nil
        }
    }

    private func target(from components: URLComponents) -> QuickConnectResult? {
        guard let host = singleValue("host", in: components) else { return nil }
        var port = 22
        if let text = singleValue("port", in: components) {
            guard let parsed = Int(text) else { return nil }
            port = parsed
        }
        return makeResult(host: host, port: port, user: singleValue("user", in: components))
    }

    /// The value of a query item that may appear at most once. `nil` when absent or repeated.
    private func singleValue(_ name: String, in components: URLComponents) -> String? {
        let matches = components.queryItems?.filter { $0.name == name } ?? []
        return matches.count == 1 ? matches[0].value : nil
    }

    // MARK: Validation

    private func makeResult(host rawHost: String, port: Int, user: String?) -> QuickConnectResult? {
        var host = rawHost
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let username = (user?.isEmpty == false ? user : nil) ?? defaultUsername
        guard Self.isValidHost(host), Self.isValidUser(username), (1...65535).contains(port) else { return nil }
        // Only host, port and user. Links never carry a jump host or a key name.
        return QuickConnectResult(target: ConnectionTarget(host: host, port: port, username: username), keyName: nil, jump: nil)
    }

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
    private static let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+")

    /// Letters, digits and `. - _ :` only, not empty, not starting with `-`.
    static func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && !host.hasPrefix("-")
            && host.unicodeScalars.allSatisfy { hostCharacters.contains($0) }
    }

    /// Letters, digits and `. _ - +` only, not empty, not starting with `-`.
    static func isValidUser(_ user: String) -> Bool {
        !user.isEmpty && user.count <= 64 && !user.hasPrefix("-")
            && user.unicodeScalars.allSatisfy { userCharacters.contains($0) }
    }
}
