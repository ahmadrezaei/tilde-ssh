import Foundation
import SwiftData
import TildeCore

/// CRUD and ordering for `ServerGroup`.
@MainActor
public final class GroupRepository {
    public let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    /// All groups in manual order.
    public func all() throws -> [ServerGroup] {
        try context.fetch(FetchDescriptor<ServerGroup>()).sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            return byName != .orderedSame ? byName == .orderedAscending : $0.id.uuidString < $1.id.uuidString
        }
    }

    public func group(id: UUID) throws -> ServerGroup? {
        var descriptor = FetchDescriptor<ServerGroup>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Appends a new group after the existing ones.
    @discardableResult
    public func add(name: String, symbol: String = "folder") throws -> ServerGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidValue("A group needs a name.") }
        let group = ServerGroup(name: trimmed, symbol: symbol, sortIndex: FractionalOrder.appended(after: try all().last?.sortIndex))
        context.insert(group)
        try context.save()
        return group
    }

    public func rename(_ group: ServerGroup, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidValue("A group needs a name.") }
        group.name = trimmed
        group.updatedAt = .now
        try context.save()
    }

    public func setCollapsed(_ group: ServerGroup, _ isCollapsed: Bool) throws {
        group.isCollapsed = isCollapsed
        group.updatedAt = .now
        try context.save()
    }

    /// Deletes the group. Its servers move to "ungrouped" (nothing else is deleted).
    public func delete(_ group: ServerGroup) throws {
        context.delete(group)
        try context.save()
    }

    /// Drag-to-reorder (SwiftUI `onMove` semantics over the displayed list). Only moved groups are rewritten.
    public func reorder(_ groups: [ServerGroup], fromOffsets offsets: IndexSet, toOffset destination: Int) throws {
        let changed = FractionalOrder.move(groups, fromOffsets: offsets, toOffset: destination, index: \.sortIndex, setIndex: { $0.sortIndex = $1 })
        for group in changed { group.updatedAt = .now }
        try context.save()
    }
}

/// CRUD for `Tag`. Names are unique case-insensitively by convention (CloudKit forbids a unique constraint,
/// so the `Deduplicator` heals races between devices).
@MainActor
public final class TagRepository {
    public let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    /// All tags, alphabetical.
    public func all() throws -> [Tag] {
        try context.fetch(FetchDescriptor<Tag>()).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The tag called `name` (case-insensitive), if any. When duplicates exist the oldest wins.
    public func tag(named name: String) throws -> Tag? {
        let wanted = Self.normalized(name)
        return try context.fetch(FetchDescriptor<Tag>())
            .filter { Self.normalized($0.name) == wanted }
            .min { isOlder($0, than: $1, created: \.createdAt, id: \.id) }
    }

    /// The existing tag or a new one.
    @discardableResult
    public func findOrCreate(_ name: String, colorHex: String? = nil) throws -> Tag {
        if let existing = try tag(named: name) { return existing }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidValue("A tag needs a name.") }
        let tag = Tag(name: trimmed, colorHex: colorHex)
        context.insert(tag)
        try context.save()
        return tag
    }

    /// Replaces the tags of `server` with the tags named `names` (creating missing ones). Blank and
    /// case-insensitively repeated names are dropped.
    public func setTags(_ names: [String], on server: Server) throws {
        var seen = Set<String>()
        var tags: [Tag] = []
        for name in names where !Self.normalized(name).isEmpty && seen.insert(Self.normalized(name)).inserted {
            tags.append(try findOrCreate(name))
        }
        server.tags = tags
        server.updatedAt = .now
        try context.save()
    }

    public func rename(_ tag: Tag, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StoreError.invalidValue("A tag needs a name.") }
        tag.name = trimmed
        tag.updatedAt = .now
        try context.save()
    }

    /// Deletes the tag; servers just lose it.
    public func delete(_ tag: Tag) throws {
        context.delete(tag)
        try context.save()
    }

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
