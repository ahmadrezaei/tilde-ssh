import Foundation
import SwiftData
import TildeCore

/// CRUD, ordering and search for `Server`. Main-actor API for SwiftUI; pass `container.mainContext`.
///
/// Every mutating method bumps `updatedAt` on the records it touches and saves the context.
@MainActor
public final class ServerRepository {
    public let context: ModelContext

    /// `lastConnectedAt` is rewritten at most this often (it syncs, so writes are throttled).
    public static let connectionWriteInterval: TimeInterval = 5 * 60

    public init(context: ModelContext) { self.context = context }

    // MARK: Reading

    /// All servers, in manual order (`sortIndex`, then name).
    public func all() throws -> [Server] {
        try context.fetch(FetchDescriptor<Server>()).sorted(by: Server.manualOrder)
    }

    /// The servers of `group` (`nil` = ungrouped), in manual order.
    public func servers(in group: ServerGroup?) throws -> [Server] {
        try all().filter { $0.group?.id == group?.id }
    }

    public func server(id: UUID) throws -> Server? {
        var descriptor = FetchDescriptor<Server>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The snapshot the SSH engine and the session UI work with.
    public func snapshot(id: UUID) throws -> ServerSnapshot? {
        try server(id: id).map { ServerSnapshot(model: $0) }
    }

    /// Servers connected to most recently, newest first (drives "recent").
    public func recentlyConnected(limit: Int = 10) throws -> [Server] {
        try all()
            .filter { $0.lastConnectedAt != nil }
            .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    /// The first server matching host, port and user (Quick Connect resolution step 1).
    public func match(_ target: ConnectionTarget) throws -> Server? {
        let host = Server.normalizedHost(target.host), port = target.port, user = target.username
        var descriptor = FetchDescriptor<Server>(predicate: #Predicate { $0.host == host && $0.port == port && $0.username == user })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Filters and ranks servers for a search string. See `ServerSearchQuery` for the syntax. An empty query
    /// returns everything in manual order; otherwise the best match comes first.
    public func search(_ input: String) throws -> [Server] {
        let query = ServerSearchQuery(parsing: input)
        let servers = try all()
        guard !query.isEmpty else { return servers }
        return servers
            .compactMap { server in query.score(server).map { (server, $0) } }
            .enumerated()
            .sorted { lhs, rhs in lhs.element.1 != rhs.element.1 ? lhs.element.1 > rhs.element.1 : lhs.offset < rhs.offset }
            .map(\.element.0)
    }

    /// Groups of servers with the same host, port and user. Never merged automatically (two servers with
    /// identical targets can be intentional, e.g. different keys); the UI shows a "Duplicate?" hint.
    public func possibleDuplicates() throws -> [[Server]] {
        let grouped = Dictionary(grouping: try all()) { "\($0.username.lowercased())@\($0.host)#\($0.port)" }
        return grouped.values.filter { $0.count > 1 }.sorted { $0[0].name < $1[0].name }
    }

    // MARK: Writing

    /// Inserts `server`: normalizes the host, validates it and appends it at the end of its group.
    @discardableResult
    public func add(_ server: Server) throws -> Server {
        server.host = Server.normalizedHost(server.host)
        try Self.validate(server)
        if server.name.nilIfBlank == nil { server.name = server.host }
        let siblings = try servers(in: server.group)
        server.sortIndex = FractionalOrder.appended(after: siblings.last?.sortIndex)
        server.updatedAt = .now
        context.insert(server)
        try context.save()
        return server
    }

    /// Creates a server from a Quick Connect result ("Save as server..."), resolving the key by name and the
    /// jump host by target among the saved servers.
    @discardableResult
    public func createServer(
        from result: QuickConnectResult,
        name: String? = nil,
        auth: AuthMethod = .key,
        passwordSecretID: UUID? = nil,
        group: ServerGroup? = nil
    ) throws -> Server {
        let server = Server(quickConnect: result, name: name, auth: auth, passwordSecretID: passwordSecretID)
        server.group = group
        if let keyName = result.keyName {
            var descriptor = FetchDescriptor<SSHKeyRecord>(predicate: #Predicate { $0.name == keyName })
            descriptor.fetchLimit = 1
            server.key = try context.fetch(descriptor).first
        }
        if let jump = result.jump { server.jumpServer = try match(jump) }
        return try add(server)
    }

    /// Creates a server from a snapshot (for example an imported or synced definition).
    @discardableResult
    public func createServer(from snapshot: ServerSnapshot, group: ServerGroup? = nil) throws -> Server {
        let server = Server(snapshot: snapshot)
        server.group = group
        try server.apply(snapshot, in: context)
        return try add(server)
    }

    /// Saves edits made directly to a server (the editor mutates the model and calls this).
    public func save(_ server: Server) throws {
        server.host = Server.normalizedHost(server.host)
        try Self.validate(server)
        server.updatedAt = .now
        try context.save()
    }

    /// Deletes `server`, plus snippets scoped to it. Servers that used it as a jump host lose the link.
    ///
    /// - Returns: the Keychain references that are now orphaned. The caller deletes them from the
    ///   `SecretStore` in the same user action (docs/DESIGN.md section 6.2).
    @discardableResult
    public func delete(_ server: Server) throws -> [SecretRef] {
        var orphaned: [SecretRef] = []
        if let secretID = server.passwordSecretID { orphaned.append(SecretRef(kind: .password, id: secretID)) }
        for snippet in server.snippets ?? [] { context.delete(snippet) }
        context.delete(server)
        try context.save()
        return orphaned
    }

    /// A copy named "<name> copy", placed right after the original. The password secret is not shared:
    /// a duplicate that used a saved password falls back to asking every time.
    @discardableResult
    public func duplicate(_ server: Server) throws -> Server {
        let copy = Server(
            name: "\(server.name) copy", host: server.host, port: server.port, username: server.username,
            authMethodRaw: server.authMethodRaw, environmentRaw: server.environmentRaw
        )
        if server.authMethod == .password { copy.authMethod = .passwordPrompt }
        copy.key = server.key
        copy.group = server.group
        copy.tags = server.tags
        copy.jumpServer = server.jumpServer
        copy.startupCommand = server.startupCommand
        copy.autoTmux = server.autoTmux
        copy.tmuxSessionName = server.tmuxSessionName
        copy.keepAliveSeconds = server.keepAliveSeconds
        copy.termType = server.termType
        copy.envVarsJSON = server.envVarsJSON
        copy.notes = server.notes
        context.insert(copy)
        let siblings = try servers(in: server.group).filter { $0.id != copy.id }
        let position = (siblings.firstIndex { $0.id == server.id } ?? siblings.count - 1) + 1
        FractionalOrder.insert(copy, at: position, among: siblings, index: \.sortIndex, setIndex: { $0.sortIndex = $1 })
        try context.save()
        return copy
    }

    public func setFavorite(_ server: Server, _ isFavorite: Bool) throws {
        server.isFavorite = isFavorite
        server.updatedAt = .now
        try context.save()
    }

    /// Moves `server` into `group` (`nil` = ungrouped), at `position` among that group's servers, or at the end.
    public func move(_ server: Server, to group: ServerGroup?, at position: Int? = nil) throws {
        let siblings = try servers(in: group).filter { $0.id != server.id }
        server.group = group
        FractionalOrder.insert(server, at: position ?? siblings.count, among: siblings, index: \.sortIndex, setIndex: { $0.sortIndex = $1 })
        server.updatedAt = .now
        try context.save()
    }

    /// Drag-to-reorder within one list. `siblings` is the list as displayed (manual order); the offsets
    /// follow SwiftUI's `onMove`. Only the moved servers are rewritten.
    public func reorder(_ siblings: [Server], fromOffsets offsets: IndexSet, toOffset destination: Int) throws {
        let changed = FractionalOrder.move(siblings, fromOffsets: offsets, toOffset: destination, index: \.sortIndex, setIndex: { $0.sortIndex = $1 })
        for server in changed { server.updatedAt = .now }
        try context.save()
    }

    /// Records a successful connection: sets `lastConnectedAt` (throttled, see `connectionWriteInterval`).
    /// Returns whether it wrote.
    @discardableResult
    public func recordConnection(_ server: Server, now: Date = .now) throws -> Bool {
        if let last = server.lastConnectedAt, now.timeIntervalSince(last) < Self.connectionWriteInterval { return false }
        server.lastConnectedAt = now
        try context.save()
        return true
    }

    // MARK: Helpers

    static func validate(_ server: Server) throws {
        guard !server.host.isEmpty else { throw StoreError.invalidValue("Host is required.") }
        guard (1...65535).contains(server.port) else { throw StoreError.invalidValue("Port must be between 1 and 65535.") }
    }
}

extension Server {
    /// Manual order: `sortIndex`, then name, then id (stable across devices).
    static func manualOrder(_ lhs: Server, _ rhs: Server) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
