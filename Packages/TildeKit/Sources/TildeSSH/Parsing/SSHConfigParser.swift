import Foundation
import TildeCore

/// Reads the subset of `~/.ssh/config` Tilde can import: `Host` blocks with `HostName`, `User`, `Port`,
/// `IdentityFile` and `ProxyJump`.
///
/// - Keys are case-insensitive; values may follow a space, `=` or ` = `, and may be quoted.
/// - `Host a b c` produces one entry per concrete alias. Patterns containing `*`, `?` or a leading `!`
///   are not importable and are skipped; settings declared outside any `Host` block or under a wildcard
///   pattern are ignored too.
/// - `Match` blocks, `Include`, `ProxyCommand` and every other keyword are ignored.
/// - As in OpenSSH, the first value given for a single-valued keyword wins, and `IdentityFile` accumulates.
public struct SSHConfigParser: SSHConfigParsing {
    public init() {}

    public func parse(_ text: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var indexByAlias: [String: Int] = [:]
        /// Aliases of the block currently being read; empty while inside a skipped block.
        var current: [String] = []

        // A settings value seen in this block, applied once per alias at the end of each assignment.
        func update(_ change: (inout SSHConfigHost) -> Void) {
            for alias in current {
                guard let index = indexByAlias[alias] else { continue }
                change(&hosts[index])
            }
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let (keyword, value) = Self.keywordAndValue(from: String(rawLine)) else { continue }

            switch keyword {
            case "host":
                current = []
                for pattern in Self.splitArguments(value) {
                    guard Self.isConcreteAlias(pattern) else { continue }
                    current.append(pattern)
                    if indexByAlias[pattern] == nil {
                        indexByAlias[pattern] = hosts.count
                        hosts.append(SSHConfigHost(alias: pattern))
                    }
                }
            case "match":
                current = []
            case "hostname":
                update { if $0.hostName == nil { $0.hostName = value } }
            case "user":
                update { if $0.user == nil { $0.user = value } }
            case "port":
                if let port = Int(value), (1...65535).contains(port) {
                    update { if $0.port == nil { $0.port = port } }
                }
            case "identityfile":
                update { $0.identityFiles.append(value) }
            case "proxyjump":
                if value.lowercased() != "none" {
                    update { if $0.proxyJump == nil { $0.proxyJump = value } }
                }
            default:
                break
            }
        }
        return hosts
    }

    // MARK: Line handling

    /// Splits one config line into a lowercased keyword and its (unquoted) value; `nil` for blank lines and comments.
    static func keywordAndValue(from line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        // The keyword ends at the first whitespace or `=`.
        guard let end = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else { return nil }
        let keyword = trimmed[..<end].lowercased()

        // Skip the separator: whitespace, then at most one `=`, then whitespace again.
        var rest = trimmed[end...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst() }
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })

        let value = stripTrailingComment(String(rest)).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return (keyword, unquote(value))
    }

    /// Removes a ` # comment` suffix that is not inside quotes.
    private static func stripTrailingComment(_ value: String) -> String {
        var inQuotes = false
        var previousWasSpace = false
        for index in value.indices {
            let char = value[index]
            if char == "\"" { inQuotes.toggle() }
            if char == "#", !inQuotes, previousWasSpace {
                return String(value[..<index])
            }
            previousWasSpace = (char == " " || char == "\t")
        }
        return value
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// Splits `Host` arguments, honouring double quotes.
    private static func splitArguments(_ value: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var inQuotes = false
        for char in value {
            if char == "\"" {
                inQuotes.toggle()
            } else if (char == " " || char == "\t"), !inQuotes {
                if !current.isEmpty { arguments.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { arguments.append(current) }
        return arguments
    }

    private static func isConcreteAlias(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?")
    }
}
