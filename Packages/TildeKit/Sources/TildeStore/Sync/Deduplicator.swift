import Foundation
import SwiftData
import TildeCore

/// What a `Deduplicator` pass did.
public struct DeduplicationReport: Equatable, Sendable {
    public var tagsMerged = 0
    public var groupsMerged = 0
    public var knownHostsMerged = 0
    /// Pins newly marked `conflicted` (two different keys for one endpoint and algorithm).
    public var knownHostConflicts = 0
    public var snippetSeedsMerged = 0

    public init() {}

    /// Number of records deleted or changed.
    public var total: Int { tagsMerged + groupsMerged + knownHostsMerged + knownHostConflicts + snippetSeedsMerged }
}

/// Heals the duplicates CloudKit can produce (the schema has no unique constraints), following
/// docs/DESIGN.md section 6.3. Every device must pick the same survivor, so records are ranked by
/// `createdAt`, then `id`.
///
/// - `Tag`: same lowercased name. Keeps the oldest, moves the servers over, deletes the rest.
/// - `ServerGroup`: same name **and** the same members (or both empty). Same name with different members is
///   legitimate and kept.
/// - `KnownHost`: same endpoint, algorithm and key: keeps the oldest. Same endpoint and algorithm with a
///   **different** key is a conflict: both are marked `conflicted` and never resolved automatically. The
///   exception is a pin that another candidate's history lists as replaced: that is a normal key rotation whose
///   deletion has not synced yet, so the superseded pin is dropped instead.
/// - `Snippet` seeds: same `seedID`.
/// - `Server` is never deduplicated.
///
/// The pass is idempotent; running it twice changes nothing the second time.
public enum Deduplicator {
    /// Runs every rule once and saves if anything changed. Call on the actor that owns `context`.
    @discardableResult
    public static func run(in context: ModelContext) throws -> DeduplicationReport {
        var report = DeduplicationReport()
        try mergeTags(in: context, report: &report)
        try mergeGroups(in: context, report: &report)
        try mergeKnownHosts(in: context, report: &report)
        try mergeSnippetSeeds(in: context, report: &report)
        if context.hasChanges { try context.save() }
        return report
    }

    // MARK: Tags

    static func mergeTags(in context: ModelContext, report: inout DeduplicationReport) throws {
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let buckets = Dictionary(grouping: tags) { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for (name, bucket) in buckets where bucket.count > 1 && !name.isEmpty {
            let ordered = bucket.sorted { isOlder($0, than: $1, created: \.createdAt, id: \.id) }
            let keeper = ordered[0]
            for loser in ordered.dropFirst() {
                for server in loser.servers ?? [] {
                    var serverTags = server.tags ?? []
                    serverTags.removeAll { $0.id == loser.id }
                    if !serverTags.contains(where: { $0.id == keeper.id }) { serverTags.append(keeper) }
                    server.tags = serverTags
                }
                if keeper.colorHex == nil { keeper.colorHex = loser.colorHex }
                context.delete(loser)
                report.tagsMerged += 1
            }
        }
    }

    // MARK: Groups

    static func mergeGroups(in context: ModelContext, report: inout DeduplicationReport) throws {
        let groups = try context.fetch(FetchDescriptor<ServerGroup>())
        let byName = Dictionary(grouping: groups) { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (_, sameName) in byName where sameName.count > 1 {
            // Within one name, only groups with identical membership (including "empty") are copies.
            let byMembers = Dictionary(grouping: sameName) { group in
                (group.servers ?? []).map(\.id.uuidString).sorted().joined(separator: ",")
            }
            for (_, copies) in byMembers where copies.count > 1 {
                let ordered = copies.sorted { isOlder($0, than: $1, created: \.createdAt, id: \.id) }
                let keeper = ordered[0]
                for loser in ordered.dropFirst() {
                    for server in loser.servers ?? [] where server.group?.id != keeper.id { server.group = keeper }
                    context.delete(loser)
                    report.groupsMerged += 1
                }
            }
        }
    }

    // MARK: Known hosts

    static func mergeKnownHosts(in context: ModelContext, report: inout DeduplicationReport) throws {
        let hosts = try context.fetch(FetchDescriptor<KnownHost>()).filter { $0.status != .revoked }
        let buckets = Dictionary(grouping: hosts) { "\($0.endpoint)\u{0}\($0.algorithm)" }
        for (_, bucket) in buckets {
            // 1. Collapse copies of the same key, keeping the oldest.
            var byKey: [String: [KnownHost]] = [:]
            for host in bucket { byKey[host.publicKeyBase64, default: []].append(host) }
            var survivors: [KnownHost] = []
            for (_, copies) in byKey {
                let ordered = copies.sorted { isOlder($0, than: $1, created: \.firstSeenAt, id: \.id) }
                let keeper = ordered[0]
                for loser in ordered.dropFirst() {
                    keeper.lastSeenAt = max(keeper.lastSeenAt, loser.lastSeenAt)
                    // A conflict flag on any copy of a key must survive the merge.
                    if loser.status == .conflicted { keeper.status = .conflicted }
                    if keeper.historyJSON == nil, loser.historyJSON != nil { keeper.historyJSON = loser.historyJSON }
                    context.delete(loser)
                    report.knownHostsMerged += 1
                }
                survivors.append(keeper)
            }
            guard survivors.count > 1 else {
                // The conflict was resolved elsewhere (the other candidates were deleted).
                if let only = survivors.first, only.status == .conflicted {
                    only.status = .trusted
                    only.updatedAt = .now
                }
                continue
            }

            // 2. Drop pins another candidate lists as replaced: a key rotation whose deletion has not synced yet.
            let superseded = Set(survivors.flatMap { $0.history.map(\.fingerprintSHA256) })
            var remaining: [KnownHost] = []
            for host in survivors {
                if superseded.contains(host.fingerprintSHA256) {
                    context.delete(host)
                    report.knownHostsMerged += 1
                } else {
                    remaining.append(host)
                }
            }

            // 3. Different keys for one endpoint and algorithm: a conflict, never auto-resolved.
            if remaining.count > 1 {
                for host in remaining where host.status != .conflicted {
                    host.status = .conflicted
                    host.updatedAt = .now
                    report.knownHostConflicts += 1
                }
            } else if let only = remaining.first, only.status == .conflicted {
                only.status = .trusted
                only.updatedAt = .now
            }
        }
    }

    // MARK: Snippet seeds

    static func mergeSnippetSeeds(in context: ModelContext, report: inout DeduplicationReport) throws {
        let snippets = try context.fetch(FetchDescriptor<Snippet>()).filter { $0.seedID != nil }
        let buckets = Dictionary(grouping: snippets) { $0.seedID ?? "" }
        for (_, copies) in buckets where copies.count > 1 {
            let ordered = copies.sorted { isOlder($0, than: $1, created: \.createdAt, id: \.id) }
            for loser in ordered.dropFirst() {
                context.delete(loser)
                report.snippetSeedsMerged += 1
            }
        }
    }
}
