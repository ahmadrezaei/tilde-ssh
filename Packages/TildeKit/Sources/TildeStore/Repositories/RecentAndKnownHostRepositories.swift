import Foundation
import SwiftData
import TildeCore

/// Recent Quick Connect targets (last 10, synced; pruned on read).
@MainActor
public final class RecentRepository {
    public let context: ModelContext

    /// How many recents are kept.
    public static let limit = 10

    public init(context: ModelContext) { self.context = context }

    /// The most recent targets, newest first. Entries beyond `limit` are deleted here ("pruning is done on read"),
    /// and entries that two devices created for the same target are collapsed.
    public func recents() throws -> [RecentConnection] {
        let sorted = try context.fetch(FetchDescriptor<RecentConnection>()).sorted { $0.lastUsedAt > $1.lastUsedAt }
        var seen = Set<String>()
        var kept: [RecentConnection] = []
        var changed = false
        for recent in sorted {
            if kept.count < Self.limit, seen.insert(recent.target).inserted {
                kept.append(recent)
            } else {
                context.delete(recent)
                changed = true
            }
        }
        if changed { try context.save() }
        return kept
    }

    /// Notes that `target` (e.g. `deploy@10.0.4.12:2222`) was just connected to.
    @discardableResult
    public func record(target: String, server: Server? = nil, at date: Date = .now) throws -> RecentConnection {
        let existing = try context.fetch(FetchDescriptor<RecentConnection>()).first { $0.target == target }
        let recent = existing ?? RecentConnection(target: target)
        recent.lastUsedAt = date
        recent.updatedAt = date
        if let server { recent.server = server }
        if existing == nil { context.insert(recent) }
        try context.save()
        _ = try recents()
        return recent
    }

    public func clear() throws {
        for recent in try context.fetch(FetchDescriptor<RecentConnection>()) { context.delete(recent) }
        try context.save()
    }

    /// Formats a target as OpenSSH-style `user@host[:port]`.
    public static func format(_ target: ConnectionTarget) -> String {
        let base = target.username.isEmpty ? target.host : "\(target.username)@\(target.host)"
        return target.port == 22 ? base : "\(base):\(target.port)"
    }
}

/// Reads and edits pinned host keys for the Known Hosts settings screen. The SSH engine uses
/// `SwiftDataKnownHostsStore` instead (it runs off the main actor).
@MainActor
public final class KnownHostRepository {
    public let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    /// Every pin except revoked ones, ordered by endpoint, then algorithm.
    public func all() throws -> [KnownHost] {
        try context.fetch(FetchDescriptor<KnownHost>())
            .filter { $0.status != .revoked }
            .sorted { ($0.endpoint, $0.algorithm) < ($1.endpoint, $1.algorithm) }
    }

    /// Pins in the `conflicted` state (two devices pinned different keys).
    public func conflicts() throws -> [KnownHost] { try all().filter { $0.status == .conflicted } }

    /// Forgets one pin ("Forget host key"). The deletion syncs to the other devices. If it was one of several
    /// conflicting candidates, the remaining one stays `conflicted`: only `trust(replacing: true)` (the
    /// changed-key screen) or forgetting the whole endpoint clears a conflict.
    public func forget(_ host: KnownHost) throws {
        context.delete(host)
        try context.save()
    }

    /// Forgets every pin of an endpoint.
    public func forget(endpoint: HostEndpoint) throws {
        let canonical = endpoint.normalized.canonical
        for host in try context.fetch(FetchDescriptor<KnownHost>(predicate: #Predicate { $0.endpoint == canonical })) {
            context.delete(host)
        }
        try context.save()
    }

    /// Adds pins parsed from a `known_hosts` file. Existing identical pins are left alone; an endpoint that
    /// already has a different key for the algorithm is skipped (never overwritten silently).
    ///
    /// - Returns: how many pins were added.
    @discardableResult
    public func importPins(_ entries: [(endpoint: HostEndpoint, key: HostKey)], deviceName: String) throws -> Int {
        var added = 0
        for (endpoint, key) in entries {
            let canonical = endpoint.normalized.canonical
            let algorithm = key.algorithm
            let existing = try context.fetch(FetchDescriptor<KnownHost>(predicate: #Predicate { $0.endpoint == canonical && $0.algorithm == algorithm }))
            guard existing.isEmpty else { continue }
            let host = KnownHost(
                endpoint: canonical, algorithm: key.algorithm, publicKeyBase64: key.blobBase64,
                fingerprintSHA256: key.fingerprintSHA256, trustedOnDevice: deviceName, sourceRaw: KnownHostSource.imported.rawValue
            )
            context.insert(host)
            added += 1
        }
        try context.save()
        return added
    }
}
