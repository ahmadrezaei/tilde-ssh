import Foundation
import SwiftData
import TildeCore
import TildeStore

/// Thin, isolated mutations on the SwiftData store used by the UI. Writes go through TildeStore's repositories where
/// they do the same job; ordering, duplicate and import keep their own logic (the UI's drag-reorder semantics).
@MainActor
struct ServerActions {
    let context: ModelContext
    let secrets: any SecretStore

    private var servers: ServerRepository { ServerRepository(context: context) }
    private var groups: GroupRepository { GroupRepository(context: context) }

    func save() {
        do { try context.save() } catch { assertionFailure("Saving the store failed: \(error)") }
    }

    // MARK: Servers

    func toggleFavorite(_ server: Server) {
        do { try servers.setFavorite(server, !server.isFavorite) } catch { assertionFailure("Saving the store failed: \(error)") }
    }

    /// Deletes the server and, once the row is gone, the Keychain secrets nothing else references any more.
    func delete(_ server: Server) {
        let serverID = server.id
        let orphaned: [SecretRef]
        do { orphaned = try servers.delete(server) } catch {
            assertionFailure("Saving the store failed: \(error)")
            return
        }
        // A secret id copied between servers (a synced duplicate, an import) stays while another server uses it.
        let stillUsed = Set(((try? context.fetch(FetchDescriptor<Server>())) ?? [])
            .filter { $0.id != serverID }.compactMap(\.passwordSecretID))
        for ref in orphaned where !stillUsed.contains(ref.id) { try? secrets.delete(ref) }
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
        guard let server = try? servers.server(id: serverID) else { return }
        _ = try? servers.recordConnection(server)
    }

    /// Removes the pinned host keys of a server ("Forget host key").
    func forgetHostKey(for server: Server) {
        try? KnownHostRepository(context: context).forget(endpoint: HostEndpoint(host: server.host, port: server.port))
    }

    // MARK: Import

    /// Saved servers as snapshots, so the import view can flag hosts that already exist.
    func savedSnapshots() -> [ServerSnapshot] {
        ((try? context.fetch(FetchDescriptor<Server>())) ?? []).map { ServerSnapshot(model: $0) }
    }

    /// Creates servers from parsed `~/.ssh/config` hosts (the import UI lives elsewhere; this stores what the user chose).
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
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let group = try? groups.add(name: trimmed) { return group }
        // The repository only fails when the save fails; hand back an unsaved group rather than crash the UI.
        assertionFailure("Creating the group failed")
        return ServerGroup(name: trimmed)
    }

    func rename(_ group: ServerGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try? groups.rename(group, to: trimmed)
    }

    func delete(_ group: ServerGroup) {
        // Servers fall back to "Ungrouped".
        try? groups.delete(group)
    }

    func setCollapsed(_ group: ServerGroup, _ collapsed: Bool) {
        try? groups.setCollapsed(group, collapsed)
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
        _ = try? RecentRepository(context: context).record(target: QuickConnectResolver.recentString(target), server: server)
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
