import Foundation
import SwiftData
import TildeCore

/// The JSON file written by "Export servers" and read by "Import servers". It contains **no secrets**: no
/// passwords, no Keychain identifiers, no key material. A key is referenced by its public SHA256 fingerprint,
/// and a saved-password server is exported as "ask every time".
public struct ServerExportDocument: Codable, Equatable, Sendable {
    public static let formatName = "tilde-servers"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var groups: [Group]
    public var servers: [Entry]

    public struct Group: Codable, Equatable, Sendable {
        public var name: String
        public var symbol: String
        public var sortIndex: Double
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var host: String
        public var port: Int
        public var username: String
        /// `key` / `passwordPrompt` (saved passwords are never exported).
        public var auth: String
        /// SHA256 fingerprint of the key's public half, for re-linking on import.
        public var keyFingerprint: String?
        public var keyName: String?
        public var environment: String
        public var group: String?
        public var tags: [String]
        /// `id` of another entry in this file.
        public var jumpServerID: UUID?
        public var isFavorite: Bool
        public var sortIndex: Double
        public var startupCommand: String?
        public var autoTmux: Bool
        public var tmuxSessionName: String
        public var keepAliveSeconds: Int
        public var termType: String
        public var envVars: [String: String]
        public var notes: String?
    }
}

/// Why a file could not be imported.
public enum ServerImportError: Error, Equatable, Sendable {
    case notAServerExport
    case unsupportedVersion(Int)
    case malformed(String)
}

/// What an import did.
public struct ServerImportReport: Equatable, Sendable {
    public var imported = 0
    /// Entries skipped because the same server (same id, or same name, host, port and user) already exists.
    public var skippedExisting = 0
    /// Entries skipped because they are invalid (empty host, bad port).
    public var skippedInvalid = 0
    /// Servers whose key could not be found on this device (they keep key auth with no key selected).
    public var unresolvedKeys = 0
    /// Saved-password servers that became "ask every time".
    public var passwordsNotImported = 0

    public init() {}
}

/// JSON export and import of servers (Settings > Data).
public enum ServerExporter {
    // MARK: Export

    /// Encodes `servers` (all by default) as pretty-printed, key-sorted JSON.
    @MainActor
    public static func export(_ servers: [Server], groups: [ServerGroup] = [], now: Date = .now) throws -> Data {
        let ordered = servers.sorted(by: Server.manualOrder)
        let usedGroupNames = Set(ordered.compactMap { $0.group?.name })
        let groupEntries = groups
            .filter { usedGroupNames.contains($0.name) }
            .map { ServerExportDocument.Group(name: $0.name, symbol: $0.symbol, sortIndex: $0.sortIndex) }
            .sorted { $0.sortIndex < $1.sortIndex }

        let entries = ordered.map { server -> ServerExportDocument.Entry in
            ServerExportDocument.Entry(
                id: server.id, name: server.name, host: server.host, port: server.port, username: server.username,
                auth: server.authMethod == .password ? AuthMethod.passwordPrompt.rawValue : server.authMethod.rawValue,
                keyFingerprint: server.key?.fingerprintSHA256, keyName: server.key?.name,
                environment: server.environment.rawValue, group: server.group?.name,
                tags: server.tagList.map(\.name).sorted(),
                jumpServerID: server.jumpServer?.id, isFavorite: server.isFavorite, sortIndex: server.sortIndex,
                startupCommand: server.startupCommand, autoTmux: server.autoTmux, tmuxSessionName: server.tmuxSessionName,
                keepAliveSeconds: server.keepAliveSeconds, termType: server.termType, envVars: server.envVars, notes: server.notes
            )
        }
        let document = ServerExportDocument(
            format: ServerExportDocument.formatName, version: ServerExportDocument.currentVersion,
            exportedAt: now, groups: groupEntries, servers: entries
        )
        return try encoder.encode(document)
    }

    /// Exports every server and group in `context`.
    @MainActor
    public static func exportAll(from context: ModelContext, now: Date = .now) throws -> Data {
        try export(context.fetch(FetchDescriptor<Server>()), groups: context.fetch(FetchDescriptor<ServerGroup>()), now: now)
    }

    // MARK: Import

    /// Parses and validates a file without touching the store.
    public static func decode(_ data: Data) throws -> ServerExportDocument {
        let document: ServerExportDocument
        do {
            document = try decoder.decode(ServerExportDocument.self, from: data)
        } catch let error as DecodingError {
            // A file that is not ours at all is a different problem than a damaged export.
            if !looksLikeExport(data) { throw ServerImportError.notAServerExport }
            throw ServerImportError.malformed(String(describing: error))
        } catch {
            throw ServerImportError.notAServerExport
        }
        guard document.format == ServerExportDocument.formatName else { throw ServerImportError.notAServerExport }
        guard document.version <= ServerExportDocument.currentVersion else { throw ServerImportError.unsupportedVersion(document.version) }
        return document
    }

    /// Imports a file into `context`. Existing servers are never modified: duplicates are skipped, so importing
    /// the same file twice is a no-op. Groups and tags are reused by name; keys are re-linked by fingerprint.
    @MainActor
    @discardableResult
    public static func `import`(_ data: Data, into context: ModelContext) throws -> ServerImportReport {
        let document = try decode(data)
        var report = ServerImportReport()

        let existingServers = try context.fetch(FetchDescriptor<Server>())
        let existingKeys = try context.fetch(FetchDescriptor<SSHKeyRecord>())
        var groupsByName = Dictionary(try context.fetch(FetchDescriptor<ServerGroup>()).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let tags = TagRepository(context: context)
        var created: [UUID: Server] = [:]
        let knownIDs = Set(existingServers.map(\.id))

        for entry in document.servers {
            let host = Server.normalizedHost(entry.host)
            guard !host.isEmpty, (1...65535).contains(entry.port) else { report.skippedInvalid += 1; continue }
            let duplicate = knownIDs.contains(entry.id) || existingServers.contains {
                $0.name == entry.name && $0.host == host && $0.port == entry.port && $0.username == entry.username
            }
            guard !duplicate else { report.skippedExisting += 1; continue }

            let server = Server(name: entry.name.nilIfBlank ?? host, host: host, port: entry.port, username: entry.username)
            server.id = entry.id
            var auth = AuthMethod(rawValue: entry.auth) ?? .key
            if auth == .password { auth = .passwordPrompt; report.passwordsNotImported += 1 }
            server.authMethod = auth
            server.environment = ServerEnvironment(rawValue: entry.environment) ?? .none
            server.isFavorite = entry.isFavorite
            server.sortIndex = entry.sortIndex
            server.startupCommand = entry.startupCommand
            server.autoTmux = entry.autoTmux
            server.tmuxSessionName = entry.tmuxSessionName
            server.keepAliveSeconds = entry.keepAliveSeconds
            server.termType = entry.termType
            server.envVars = entry.envVars
            server.notes = entry.notes

            if auth == .key {
                if let fingerprint = entry.keyFingerprint, let key = existingKeys.first(where: { $0.fingerprintSHA256 == fingerprint }) {
                    server.key = key
                } else if entry.keyFingerprint != nil {
                    report.unresolvedKeys += 1
                }
            }
            if let groupName = entry.group?.nilIfBlank {
                if let group = groupsByName[groupName] {
                    server.group = group
                } else {
                    let info = document.groups.first { $0.name == groupName }
                    let group = ServerGroup(name: groupName, symbol: info?.symbol ?? "folder", sortIndex: info?.sortIndex ?? FractionalOrder.step)
                    context.insert(group)
                    groupsByName[groupName] = group
                    server.group = group
                }
            }
            context.insert(server)
            var serverTags: [Tag] = []
            for name in entry.tags { serverTags.append(try tags.findOrCreate(name)) }
            server.tags = serverTags
            created[entry.id] = server
            report.imported += 1
        }

        // Second pass: jump hosts, which may refer to servers created above or already present.
        let lookup = Dictionary(existingServers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).merging(created) { _, new in new }
        for entry in document.servers {
            guard let server = created[entry.id], let jumpID = entry.jumpServerID, jumpID != entry.id else { continue }
            server.jumpServer = lookup[jumpID]
        }
        try context.save()
        return report
    }

    // MARK: Coding

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func looksLikeExport(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["format"] as? String == ServerExportDocument.formatName
    }
}
