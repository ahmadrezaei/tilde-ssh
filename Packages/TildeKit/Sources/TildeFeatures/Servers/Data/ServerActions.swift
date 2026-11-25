import Foundation
import SwiftData
import TildeCore
import TildeStore

/// Thin, isolated mutations on the SwiftData store used by the UI.
///
/// Interim: WS1 is writing `ServerRepository` & friends. Every inline mutation in the UI goes through this type, so
/// switching to the repositories later is a change in this one file.
@MainActor
struct ServerActions {
    let context: ModelContext
    let secrets: any SecretStore

    func save() {
        do { try context.save() } catch { assertionFailure("Saving the store failed: \(error)") }
    }

    // MARK: Servers

    func toggleFavorite(_ server: Server) {
        server.isFavorite.toggle()
        touch(server)
    }

    func delete(_ server: Server) {
        if let secretID = server.passwordSecretID {
            let sharedElsewhere = ((try? context.fetch(FetchDescriptor<Server>())) ?? [])
                .contains { $0.id != server.id && $0.passwordSecretID == secretID }
            if !sharedElsewhere { try? secrets.delete(SecretRef(kind: .password, id: secretID)) }
        }
        context.delete(server)
        save()
    }

    @discardableResult
    func duplicate(_ server: Server) -> Server {
        let copy = Server(name: "\(server.name) copy", host: server.host, port: server.port, username: server.username,
                          authMethodRaw: server.authMethodRaw, environmentRaw: server.environmentRaw)
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
        copy.sortIndex = nextSortIndex(in: server.group)
        // Passwords are copied into a new Keychain item so deleting one server never breaks the other.
        if let oldID = server.passwordSecretID,
           let data = try? secrets.read(SecretRef(kind: .password, id: oldID)) {
            let newID = UUID()
            try? secrets.write(data, for: SecretRef(kind: .password, id: newID), label: "Tilde: \(copy.username)@\(copy.host)", synchronizable: true)
            copy.passwordSecretID = newID
        }
        context.insert(copy)
        save()
        return copy
    }

    func move(_ server: Server, to group: ServerGroup?) {
        guard server.group?.id != group?.id else { return }
        server.group = group
        server.sortIndex = nextSortIndex(in: group)
        touch(server)
    }

    /// Applies a drag-reorder. `servers` is the displayed (sorted) list of one section.
    func reorder(_ servers: [Server], fromOffsets: IndexSet, toOffset: Int) {
        let changes = FractionalOrder.move(
            items: servers.map { (id: $0.id, index: $0.sortIndex) },
            fromOffsets: fromOffsets, toOffset: toOffset
        )
        for server in servers {
            if let index = changes[server.id] { server.sortIndex = index; server.updatedAt = .now }
        }
        save()
    }

    func nextSortIndex(in group: ServerGroup?) -> Double {
        let all = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        let siblings = all.filter { $0.group?.id == group?.id }
        return FractionalOrder.next(after: siblings.map(\.sortIndex))
    }

    /// Updates `lastConnectedAt`, at most every 5 minutes per server (it syncs, so writes are throttled).
    func touchConnected(serverID: UUID) {
        var descriptor = FetchDescriptor<Server>(predicate: #Predicate { $0.id == serverID })
        descriptor.fetchLimit = 1
        guard let server = try? context.fetch(descriptor).first else { return }
        if let last = server.lastConnectedAt, Date.now.timeIntervalSince(last) < 300 { return }
        server.lastConnectedAt = .now
        save()
    }

    /// Removes the pinned host keys of a server ("Forget host key").
    func forgetHostKey(for server: Server) {
        let canonical = HostEndpoint(host: server.host, port: server.port).canonical
        let pins = (try? context.fetch(FetchDescriptor<KnownHost>(predicate: #Predicate { $0.endpoint == canonical }))) ?? []
        pins.forEach(context.delete)
        save()
    }

    // MARK: Import

    /// Creates servers from parsed `~/.ssh/config` hosts (the import UI is WS6's; this stores what the user chose).
    /// Skips hosts that already exist (same host, port and user). A key is attached only when a key named like the
    /// identity file exists; otherwise the server asks for a password.
    @discardableResult
    func importHosts(_ hosts: [SSHConfigHost]) -> [Server] {
        let existing = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        let keys = (try? context.fetch(FetchDescriptor<SSHKeyRecord>())) ?? []
        var next = FractionalOrder.next(after: existing.filter { $0.group == nil }.map(\.sortIndex))
        var created: [(Server, SSHConfigHost)] = []

        for entry in hosts {
            let host = (entry.hostName ?? entry.alias).lowercased()
            let port = entry.port ?? 22
            let user = entry.user ?? TildeSettings.currentDefaultUser
            if existing.contains(where: { $0.host.lowercased() == host && $0.port == port && $0.username == user }) { continue }
            let identity = entry.identityFiles.first.map { URL(fileURLWithPath: $0).lastPathComponent }
            let key = identity.flatMap { name in keys.first { $0.name == name } }
            let server = Server(name: entry.alias, host: host, port: port, username: user,
                                authMethodRaw: key == nil ? AuthMethod.passwordPrompt.rawValue : AuthMethod.key.rawValue)
            server.key = key
            server.importedFrom = "ssh_config:Host \(entry.alias)"
            server.sortIndex = next
            next += 1
            context.insert(server)
            created.append((server, entry))
        }

        // ProxyJump: the first hop, matched by alias or host among existing and imported servers.
        let all = existing + created.map(\.0)
        for (server, entry) in created {
            guard let hop = entry.proxyJump?.split(separator: ",").first.map(String.init) else { continue }
            let hopHost = hop.split(separator: "@").last.map(String.init)?.split(separator: ":").first.map(String.init) ?? hop
            server.jumpServer = all.first { $0.id != server.id && ($0.name == hopHost || $0.host.lowercased() == hopHost.lowercased()) }
        }
        save()
        return created.map(\.0)
    }

    // MARK: Groups

    @discardableResult
    func createGroup(named name: String) -> ServerGroup {
        let groups = (try? context.fetch(FetchDescriptor<ServerGroup>())) ?? []
        let group = ServerGroup(name: name.trimmingCharacters(in: .whitespaces), sortIndex: FractionalOrder.next(after: groups.map(\.sortIndex)))
        context.insert(group)
        save()
        return group
    }

    func rename(_ group: ServerGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        group.name = trimmed
        group.updatedAt = .now
        save()
    }

    func delete(_ group: ServerGroup) {
        // The relationship is `.nullify`: servers fall back to "Ungrouped".
        context.delete(group)
        save()
    }

    func setCollapsed(_ group: ServerGroup, _ collapsed: Bool) {
        group.isCollapsed = collapsed
        group.updatedAt = .now
        save()
    }

    // MARK: Tags

    /// Finds a tag by case-insensitive name, creating it if needed (CloudKit has no unique constraints, so the
    /// Deduplicator cleans up races between devices).
    func tag(named name: String) -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let existing = ((try? context.fetch(FetchDescriptor<Tag>())) ?? [])
            .first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if let existing { return existing }
        let tag = Tag(name: trimmed)
        context.insert(tag)
        return tag
    }

    // MARK: Recents

    /// Records a Quick Connect (design section 4.4). Keeps the 10 most recent.
    func recordRecent(_ target: ConnectionTarget, server: Server?) {
        let key = QuickConnectResolver.recentString(target)
        let recents = (try? context.fetch(FetchDescriptor<RecentConnection>(sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)]))) ?? []
        if let existing = recents.first(where: { $0.target == key }) {
            existing.lastUsedAt = .now
            existing.updatedAt = .now
        } else {
            let recent = RecentConnection(target: key, lastUsedAt: .now)
            recent.server = server
            context.insert(recent)
        }
        for stale in recents.filter({ $0.target != key }).dropFirst(9) { context.delete(stale) }
        save()
    }

    // MARK: Helpers

    private func touch(_ server: Server) {
        server.updatedAt = .now
        save()
    }
}

extension Server {
    /// The fields the search matches on.
    var searchItem: ServerSearchItem {
        ServerSearchItem(
            name: name, host: host, username: username,
            tags: (tags ?? []).map(\.name), groupName: group?.name,
            environment: ServerMapper.environment(self)
        )
    }
}
