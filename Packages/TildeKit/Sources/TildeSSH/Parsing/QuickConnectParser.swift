import Foundation
import TildeCore

/// Parses what a user types into the Quick Connect field.
///
/// Accepted forms (design section 4.4):
/// - `host`, `user@host`, `user@host:port`, `[::1]:22`, `::1` (a bare IPv6 literal has no port)
/// - `ssh://user@host:port` (a trailing path is ignored)
/// - `ssh [-p N] [-l user] [-i keyname] [-J jump] [other flags] [user@]host [command]`
///
/// When no user is given, `defaultUsername` is used (the Settings default; OpenSSH would use the local
/// account name, which is meaningless on iOS).
public struct QuickConnectParser: QuickConnectParsing {
    public var defaultUsername: String

    public init(defaultUsername: String = "root") {
        self.defaultUsername = defaultUsername
    }

    public func parse(_ input: String) -> QuickConnectResult? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }

        let tokens = Self.tokenize(trimmed)
        guard let first = tokens.first else { return nil }

        if first == "ssh" {
            return parseSSHCommand(Array(tokens.dropFirst()))
        }
        // A single destination token; whitespace anywhere else means this is not a target.
        guard tokens.count == 1 else { return nil }
        guard let destination = parseDestination(first) else { return nil }
        return QuickConnectResult(target: destination.target(defaultUsername: defaultUsername))
    }

    // MARK: ssh command line

    /// `ssh` flags that take no argument (they are skipped).
    private static let flagsWithoutArgument: Set<Character> = Set("46AaCfGgKkMNnqsTtVvXxYy")
    /// `ssh` flags that take an argument we do not use (the argument is skipped).
    private static let flagsWithIgnoredArgument: Set<Character> = Set("BbcDEeFIJLlmOopQRSWw")

    private func parseSSHCommand(_ args: [String]) -> QuickConnectResult? {
        var port: Int?
        var user: String?
        var identity: String?
        var jump: String?
        var destinationToken: String?

        var index = 0
        func value(afterFlag flag: Character, inside token: String) -> String? {
            // `-p2222` (attached) or `-p 2222` (next token).
            let attached = token.dropFirst(2)
            if !attached.isEmpty { return String(attached) }
            guard index + 1 < args.count else { return nil }
            index += 1
            return args[index]
        }

        while index < args.count {
            let token = args[index]
            if destinationToken != nil {
                // Tolerate `ssh host -p 2222 -i key` (OpenSSH would treat those as the remote command, but
                // people type it this way). The first token that is not one of our flags starts the command.
                guard token.hasPrefix("-"), token.count >= 2, "plioJ".contains(token[token.index(after: token.startIndex)]) else { break }
            }
            if token == "--" {
                index += 1
                destinationToken = index < args.count ? args[index] : nil
                break
            }
            if token.hasPrefix("-"), token.count >= 2 {
                let flag = token[token.index(after: token.startIndex)]
                switch flag {
                case "p":
                    guard let raw = value(afterFlag: flag, inside: token), let parsed = Self.validPort(raw) else { return nil }
                    port = parsed
                case "l":
                    guard let raw = value(afterFlag: flag, inside: token), !raw.isEmpty else { return nil }
                    user = raw
                case "i":
                    guard let raw = value(afterFlag: flag, inside: token), !raw.isEmpty else { return nil }
                    identity = raw
                case "J":
                    guard let raw = value(afterFlag: flag, inside: token), !raw.isEmpty else { return nil }
                    jump = raw
                case "o":
                    guard let raw = value(afterFlag: flag, inside: token) else { return nil }
                    guard Self.applyOption(raw, port: &port, user: &user, identity: &identity, jump: &jump) else { return nil }
                default:
                    if Self.flagsWithIgnoredArgument.contains(flag) {
                        guard value(afterFlag: flag, inside: token) != nil else { return nil }
                    } else if Self.flagsWithoutArgument.contains(flag) {
                        // Combined short flags such as `-tt` or `-vvv` are fine; `-Nf` too.
                    } else {
                        return nil
                    }
                }
            } else if destinationToken == nil {
                destinationToken = token
            }
            index += 1
        }

        guard let destinationToken, let destination = parseDestination(destinationToken) else { return nil }

        var target = destination.target(defaultUsername: defaultUsername)
        if let user, !destination.hadUser { target.username = user }
        if let port { target.port = port }

        var jumpTarget: ConnectionTarget?
        if let jump {
            // `-J a,b` is a chain; MVP supports one hop, so the first one is used.
            let firstHop = jump.split(separator: ",").first.map(String.init) ?? jump
            guard let parsed = parseDestination(firstHop) else { return nil }
            jumpTarget = parsed.target(defaultUsername: defaultUsername)
        }

        let keyName = identity.map { ($0 as NSString).lastPathComponent }
        return QuickConnectResult(target: target, keyName: keyName, jump: jumpTarget)
    }

    /// Handles `-o Key=value` / `-o "Key value"` for the options Tilde understands. Unknown options are ignored.
    private static func applyOption(_ raw: String, port: inout Int?, user: inout String?, identity: inout String?, jump: inout String?) -> Bool {
        let parts = raw.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == "=" || $0 == " " })
        guard parts.count == 2 else { return true }
        let key = parts[0].lowercased()
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        switch key {
        case "port":
            guard let parsed = validPort(value) else { return false }
            port = parsed
        case "user": user = value
        case "identityfile": identity = value
        case "proxyjump": jump = value
        default: break
        }
        return true
    }

    // MARK: Destination

    private struct Destination {
        var user: String?
        var host: String
        var port: Int?
        var hadUser: Bool { user != nil }

        func target(defaultUsername: String) -> ConnectionTarget {
            ConnectionTarget(host: host, port: port ?? 22, username: user ?? defaultUsername)
        }
    }

    /// Parses `[user@]host[:port]`, `[user@][v6]:port` and `ssh://[user@]host[:port][/...]`.
    private func parseDestination(_ raw: String) -> Destination? {
        var rest = Substring(raw)
        if rest.lowercased().hasPrefix("ssh://") {
            rest = rest.dropFirst(6)
            if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        }
        guard !rest.isEmpty else { return nil }

        var user: String?
        if let at = rest.lastIndex(of: "@") {
            let rawUser = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
            guard !rawUser.isEmpty else { return nil }
            user = rawUser.removingPercentEncoding ?? rawUser
        }

        var host: String
        var port: Int?
        if rest.hasPrefix("[") {
            // [v6] or [v6]:port
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let parsed = Self.validPort(String(after.dropFirst())) else { return nil }
                port = parsed
            }
        } else {
            let colonCount = rest.filter { $0 == ":" }.count
            if colonCount == 0 {
                host = String(rest)
            } else if colonCount == 1, let colon = rest.firstIndex(of: ":") {
                host = String(rest[..<colon])
                guard let parsed = Self.validPort(String(rest[rest.index(after: colon)...])) else { return nil }
                port = parsed
            } else {
                // A bare IPv6 literal: no port can be expressed without brackets.
                host = String(rest)
            }
        }

        guard Self.isValidHost(host) else { return nil }
        return Destination(user: user, host: host, port: port)
    }

    private static func validPort(_ raw: String) -> Int? {
        guard let port = Int(raw), (1...65535).contains(port) else { return nil }
        return port
    }

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        if host.contains(":") {
            // IPv6 literal, optionally with a zone id (`fe80::1%en0`).
            return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" || $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        }
        return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }
    }

    // MARK: Tokenizer

    /// Splits on whitespace honouring single quotes, double quotes and backslash escapes.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaping = false

        for char in input {
            if escaping {
                current.append(char)
                escaping = false
                continue
            }
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else if char == "\\", activeQuote == "\"" {
                    escaping = true
                } else {
                    current.append(char)
                }
                continue
            }
            switch char {
            case "\\":
                escaping = true
                inToken = true
            case "\"", "'":
                quote = char
                inToken = true
            case " ", "\t":
                if inToken {
                    tokens.append(current)
                    current = ""
                    inToken = false
                }
            default:
                current.append(char)
                inToken = true
            }
        }
        if inToken { tokens.append(current) }
        return tokens
    }
}
