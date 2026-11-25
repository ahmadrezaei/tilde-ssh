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
    /// Tags and groups that look like duplicates but are younger than the grace period, so they were left
    /// alone for now (a partial CloudKit import can show a record before its relationships). The coordinator
    /// runs another pass once the grace period has elapsed.
    public var deferred = 0

    public init() {}

    /// Number of records deleted or changed.
    public var total: Int { tagsMerged + groupsMerged + knownHostsMerged + knownHostConflicts + snippetSeedsMerged }
}

/// Heals the duplicates CloudKit can produce (the schema has no unique constraints), following
/// docs/DESIGN.md section 6.3. Every device must pick the same survivor, so records are ranked by
/// `createdAt`, then `id`.
///
/// - `Tag`: same lowercased name. Keeps the oldest, moves the servers over, deletes the rest. Only tags older
///   than the grace period are merged: a tag can arrive from CloudKit before the servers that reference it, and
///   merging then would orphan those links.
/// - `ServerGroup`: same name **and** the same members (or both empty), older than the grace period. Same name
///   with different members is legitimate and kept.
/// - `KnownHost`: same endpoint, algorithm and key: keeps the oldest. Same endpoint and algorithm with a
///   **different** key is a conflict: all candidates are marked `conflicted`. A conflict is **never cleared**
///   here, not even when one candidate remains; only `SwiftDataKnownHostsStore.trust(replacing: true)` does.
///   The one exception is a pin that another candidate's history lists as replaced while at least one
///   candidate is not superseded: that is a normal key rotation whose deletion has not synced yet, so the
///   superseded pin is dropped. If every candidate is superseded by another (two devices rotated in opposite
///   directions) nothing is deleted and they all become conflicts.
/// - `Snippet` seeds: same `seedID`; the most recently edited copy survives.
/// - `Server` is never deduplicated.
///
/// The pass is idempotent; running it twice changes nothing the second time.
public enum Deduplicator {
    /// How old a tag or group must be before it is merged.
    public static let defaultGracePeriod: TimeInterval = 10 * 60

    /// Runs every rule once and saves if anything changed. Call on the actor that owns `context`.
    ///
    /// - Parameters:
    ///   - now: the clock, injectable for tests.
    ///   - gracePeriod: tags and groups younger than this are not merged yet (counted in `deferred`).
    @discardableResult
    public static func run(in context: ModelContext, now: Date = .now, gracePeriod: TimeInterval = defaultGracePeriod) throws -> DeduplicationReport {
        var report = DeduplicationReport()
        let cutoff = now.addingTimeInterval(-gracePeriod)
        try mergeTags(in: context, cutoff: cutoff, report: &report)
        try mergeGroups(in: context, cutoff: cutoff, report: &report)
        try mergeKnownHosts(in: context, report: &report)
        try mergeSnippetSeeds(in: context, report: &report)
        if context.hasChanges { try context.save() }
        return report
    }

    // MARK: Tags

    static func mergeTags(in context: ModelContext, cutoff: Date, report: inout DeduplicationReport) throws {
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let buckets = Dictionary(grouping: tags) { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        for (name, all) in buckets where all.count > 1 && !name.isEmpty {
            let bucket = all.filter { $0.createdAt <= cutoff }
            report.deferred += all.count - bucket.count
            guard bucket.count > 1 else { continue }
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

    static func mergeGroups(in context: ModelContext, cutoff: Date, report: inout DeduplicationReport) throws {
        let groups = try context.fetch(FetchDescriptor<ServerGroup>())
        let byName = Dictionary(grouping: groups) { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (_, sameName) in byName where sameName.count > 1 {
            // Within one name, only groups with identical membership (including "empty") are copies.
            let byMembers = Dictionary(grouping: sameName) { group in
                (group.servers ?? []).map(\.id.uuidString).sorted().joined(separator: ",")
            }
            for (_, all) in byMembers where all.count > 1 {
                let copies = all.filter { $0.createdAt <= cutoff }
                report.deferred += all.count - copies.count
                guard copies.count > 1 else { continue }
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
            guard survivors.count > 1 else { continue }   // a lone pin keeps whatever status it has

            // 2. Drop pins another candidate lists as replaced (a key rotation whose deletion has not synced
            //    yet), but only if a current pin remains. If every candidate is superseded by another, they
            //    contradict each other: keep them all and flag the conflict.
            let superseded = Set(survivors.flatMap { $0.history.map(\.fingerprintSHA256) })
            let current = survivors.filter { !superseded.contains($0.fingerprintSHA256) }
            var remaining = survivors
            if !current.isEmpty {
                for host in survivors where superseded.contains(host.fingerprintSHA256) {
                    context.delete(host)
                    report.knownHostsMerged += 1
                }
                remaining = current
            }

            // 3. Different keys for one endpoint and algorithm: a conflict, never auto-resolved.
            if remaining.count > 1 {
                for host in remaining where host.status != .conflicted {
                    host.status = .conflicted
                    host.updatedAt = .now
                    report.knownHostConflicts += 1
                }
            }
        }
    }

    // MARK: Snippet seeds

    static func mergeSnippetSeeds(in context: ModelContext, report: inout DeduplicationReport) throws {
        let snippets = try context.fetch(FetchDescriptor<Snippet>()).filter { $0.seedID != nil }
        let buckets = Dictionary(grouping: snippets) { $0.seedID ?? "" }
        for (_, copies) in buckets where copies.count > 1 {
            // Keep the most recently edited copy (a user's edit to a seed wins), ties broken by id.
            let ordered = copies.sorted {
                $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id.uuidString < $1.id.uuidString
            }
            for loser in ordered.dropFirst() {
                context.delete(loser)
                report.snippetSeedsMerged += 1
            }
        }
    }
}
