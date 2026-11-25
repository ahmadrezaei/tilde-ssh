import Foundation
import Observation
import TildeCore

// MARK: - Planning (pure, testable)

/// How a host in `~/.ssh/config` reaches its target.
public enum SSHConfigJump: Equatable, Sendable {
    /// Direct connection (no `ProxyJump`, or `ProxyJump none`).
    case none
    /// A single bastion. `inConfig` is true when the token names another `Host` block in the same file.
    case single(String, inConfig: Bool)
    /// `ProxyJump a,b`. Tilde supports one hop, so these hosts import without a jump host.
    case multiHop([String])
}

/// Why a host is flagged as already present.
public enum SSHConfigConflict: Equatable, Sendable {
    /// A saved server has the same host, port and user.
    case sameTarget(serverName: String)
    /// A saved server already uses this name.
    case sameName(serverName: String)

    /// The name of the existing server.
    public var serverName: String {
        switch self {
        case .sameTarget(let name), .sameName(let name): name
        }
    }
}

/// One importable `Host` block, with everything the preview list shows.
public struct SSHConfigImportRow: Identifiable, Equatable, Sendable {
    /// Position in the file, stable for the life of one import.
    public let id: Int
    /// The parsed block. `proxyJump` is cleared for multi-hop chains, `hostName` falls back to the alias and an
    /// out-of-range `port` is dropped.
    public let host: SSHConfigHost
    /// `HostName`, or the alias when the block has none (that is what `ssh` connects to).
    public let displayHost: String
    /// `Port`, or 22.
    public let port: Int
    public let jump: SSHConfigJump
    public let conflict: SSHConfigConflict?

    /// `user@host:port` in the form the rest of the UI uses (user and port omitted when unknown or 22).
    public var summary: String {
        var text = displayHost
        if let user = host.user { text = "\(user)@\(text)" }
        if port != 22 { text += ":\(port)" }
        return text
    }
}

/// The preview list for one config file.
public struct SSHConfigImportPlan: Equatable, Sendable {
    public var rows: [SSHConfigImportRow]
    /// `Host` patterns that were left out (`*`, `*.example.com`, `!bad`): they describe defaults, not servers.
    public var skippedPatterns: [String]
}

/// Turns parsed config blocks into a preview list. Pure; no I/O.
public enum SSHConfigImportPlanner {
    /// Builds the preview.
    /// - Parameters:
    ///   - hosts: the output of `SSHConfigParsing.parse(_:)`.
    ///   - existing: servers already saved, used to flag duplicates.
    public static func plan(hosts: [SSHConfigHost], existing: [ServerSnapshot]) -> SSHConfigImportPlan {
        var rows: [SSHConfigImportRow] = []
        var skipped: [String] = []
        let aliases = Set(hosts.map { $0.alias.lowercased() })

        for host in hosts {
            let alias = host.alias.trimmingCharacters(in: .whitespaces)
            guard !alias.isEmpty else { continue }
            if isPattern(alias) {
                skipped.append(alias)
                continue
            }
            let displayHost = nonEmpty(host.hostName) ?? alias
            // An out-of-range `Port` (0, 70000) is treated as unset, in the preview and in the emitted host.
            let validPort = host.port.flatMap { (1...65535).contains($0) ? $0 : nil }
            let port = validPort ?? 22
            let jump = classifyJump(host.proxyJump, aliases: aliases)

            var normalized = host
            normalized.hostName = displayHost
            normalized.port = validPort
            if case .multiHop = jump { normalized.proxyJump = nil }
            if case .none = jump { normalized.proxyJump = nil }

            rows.append(SSHConfigImportRow(
                id: rows.count,
                host: normalized,
                displayHost: displayHost,
                port: port,
                jump: jump,
                conflict: conflict(alias: alias, host: displayHost, port: port, user: host.user, existing: existing)
            ))
        }
        return SSHConfigImportPlan(rows: rows, skippedPatterns: skipped)
    }

    /// True for `Host` patterns (`*`, `?`, negation) that do not name a single server.
    public static func isPattern(_ alias: String) -> Bool {
        alias.contains("*") || alias.contains("?") || alias.hasPrefix("!") || alias.contains(" ")
    }

    /// Classifies a `ProxyJump` value. Handles `none`, `bastion`, `user@bastion:2222` and comma chains.
    public static func classifyJump(_ value: String?, aliases: Set<String>) -> SSHConfigJump {
        guard let raw = nonEmpty(value), raw.lowercased() != "none" else { return .none }
        let hops = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !hops.isEmpty else { return .none }
        if hops.count > 1 { return .multiHop(hops) }
        let hop = hops[0]
        return .single(hop, inConfig: aliases.contains(bareHost(of: hop).lowercased()))
    }

    /// `user@host:port` -> `host`; `[::1]:22` -> `::1`; `ssh://user@host` -> `host`.
    static func bareHost(of hop: String) -> String {
        var text = hop
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            return String(text[text.index(after: text.startIndex)..<close])
        }
        if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }
        return text
    }

    private static func conflict(alias: String, host: String, port: Int, user: String?, existing: [ServerSnapshot]) -> SSHConfigConflict? {
        if let match = existing.first(where: {
            $0.target.host.caseInsensitiveCompare(host) == .orderedSame
                && $0.target.port == port
                && (user == nil || $0.target.username == user)
        }) {
            return .sameTarget(serverName: match.name)
        }
        if let match = existing.first(where: { $0.name.caseInsensitiveCompare(alias) == .orderedSame }) {
            return .sameName(serverName: match.name)
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Key files

/// A private key file the user chose while importing, offered to the app's key-import flow.
///
/// The bytes are secret material: pass them straight to `KeyService.parse` and the secret store, never log or
/// persist them elsewhere.
public struct ImportedKeyFile: Sendable {
    /// The file name (for example `id_ed25519`), used as the suggested key name.
    public let name: String
    /// Raw file contents (OpenSSH or PEM private key).
    public let data: Data
    /// The `IdentityFile` values from the config that point at this file (matched by file name), so the caller
    /// can link imported servers to the imported key.
    public let configPaths: [String]

    public init(name: String, data: Data, configPaths: [String]) {
        self.name = name
        self.data = data
        self.configPaths = configPaths
    }
}

// MARK: - Model

/// State behind `SSHConfigImportView`. Main-actor and observable; owns no I/O beyond reading the files it is given.
@MainActor
@Observable
public final class SSHConfigImportModel {
    /// File name shown in the header (for example `config`).
    public private(set) var sourceName: String?
    /// The preview list.
    public private(set) var plan = SSHConfigImportPlan(rows: [], skippedPatterns: [])
    /// Ids of the checked rows.
    public var selection: Set<Int> = []
    /// Key files chosen so far.
    public private(set) var keyFiles: [ImportedKeyFile] = []
    /// A user-facing error, if the last file could not be used.
    public private(set) var errorMessage: String?

    private let parser: any SSHConfigParsing
    private let existing: [ServerSnapshot]

    /// - Parameters:
    ///   - parser: usually `services.sshConfig`.
    ///   - existing: servers already saved, so duplicates can be flagged and left unchecked.
    public init(parser: any SSHConfigParsing, existing: [ServerSnapshot] = []) {
        self.parser = parser
        self.existing = existing
    }

    /// Parses `text` and rebuilds the preview. Hosts that clash with a saved server start unchecked.
    public func load(text: String, sourceName: String?) {
        self.sourceName = sourceName
        errorMessage = nil
        plan = SSHConfigImportPlanner.plan(hosts: parser.parse(text), existing: existing)
        selection = Set(plan.rows.filter { $0.conflict == nil }.map(\.id))
        keyFiles = []
        if plan.rows.isEmpty {
            errorMessage = "No servers found. Wildcard-only entries such as “Host *” describe defaults, not servers."
        }
    }

    /// Records a file read failure.
    public func fail(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    /// The checked rows, in file order.
    public var selectedRows: [SSHConfigImportRow] {
        plan.rows.filter { selection.contains($0.id) }
    }

    /// The hosts to hand to the app: checked rows only.
    public var selectedHosts: [SSHConfigHost] { selectedRows.map(\.host) }

    /// Unique `IdentityFile` paths referenced by the checked rows, in first-seen order.
    public var requestedIdentityFiles: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in selectedRows.flatMap(\.host.identityFiles) where path.lowercased() != "none" {
            if seen.insert(path).inserted { result.append(path) }
        }
        return result
    }

    /// Jump hosts referenced by checked rows that are defined in the file but not checked.
    public var unselectedJumpAliases: [String] {
        let selectedAliases = Set(selectedRows.map { $0.host.alias.lowercased() })
        var result: [String] = []
        for case .single(let hop, true) in selectedRows.map(\.jump) {
            let name = SSHConfigImportPlanner.bareHost(of: hop)
            if !selectedAliases.contains(name.lowercased()), !result.contains(name) { result.append(name) }
        }
        return result
    }

    /// Checks every row, duplicates included.
    public func selectAll() { selection = Set(plan.rows.map(\.id)) }

    /// Unchecks everything.
    public func selectNone() { selection = [] }

    /// Adds key files the user picked. Each is matched to the config paths that name it.
    public func addKeyFiles(_ files: [(name: String, data: Data)]) {
        let wanted = requestedIdentityFiles
        for file in files where !keyFiles.contains(where: { $0.name == file.name }) {
            let paths = wanted.filter { ($0 as NSString).lastPathComponent == file.name }
            keyFiles.append(ImportedKeyFile(name: file.name, data: file.data, configPaths: paths))
        }
    }

    /// Whether anything is checked.
    public var canImport: Bool { !selection.isEmpty }
}
