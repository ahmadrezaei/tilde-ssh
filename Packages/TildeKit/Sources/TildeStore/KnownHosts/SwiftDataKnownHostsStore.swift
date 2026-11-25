import Foundation
import OSLog
import SwiftData
import TildeCore

/// The synced TOFU pin store, implementing the `KnownHostsStore` contract on SwiftData.
///
/// It is a `ModelActor`: it owns a private `ModelContext` and runs on its own executor, so the SSH engine's
/// actors can call it directly without touching the main context. Only Sendable values (`HostKey`,
/// `HostKeyLookup`, ...) cross its boundary.
///
/// Lookup rules (`lookup(_:presented:)`):
/// - no usable pin for the endpoint: `.unknown`
/// - any pin in the `conflicted` state, or two different keys pinned for the same algorithm (two devices
///   trusted different keys before the `Deduplicator` ran): `.conflicted`, never auto-resolved
/// - the same algorithm and key pinned: `.trusted`
/// - otherwise `.mismatch`. A presented algorithm that has no pin while other algorithms are pinned is also
///   a mismatch (the same choice as `InMemoryKnownHostsStore`): an unexpected key type for a pinned host is
///   suspicious, so the UI shows the changed-key screen instead of a first-connection prompt.
///
/// Revoked pins (forgotten by the user) are ignored.
public actor SwiftDataKnownHostsStore: KnownHostsStore, ModelActor {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    private let deviceName: String
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "app.tildessh.Tilde", category: "KnownHosts")

    /// `lastSeenAt` is rewritten at most once per this interval (a day) to limit sync churn.
    public static let touchInterval: TimeInterval = 24 * 60 * 60

    /// - Parameters:
    ///   - modelContainer: the app's container (CloudKit-backed in production, in-memory in tests).
    ///   - deviceName: stored as `trustedOnDevice` on new pins.
    ///   - now: the clock, injectable for tests.
    public init(modelContainer: ModelContainer, deviceName: String = DeviceInfo.name, now: @escaping @Sendable () -> Date = { .now }) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.deviceName = deviceName
        self.now = now
    }

    // MARK: KnownHostsStore

    public func lookup(_ endpoint: HostEndpoint, presented: HostKey) async -> HostKeyLookup {
        let rows: [KnownHost]
        do { rows = try pins(for: endpoint) } catch {
            logger.error("Known host lookup failed: \(error.localizedDescription, privacy: .public)")
            return .unknown
        }
        guard !rows.isEmpty else { return .unknown }

        let conflicted = rows.filter { $0.status == .conflicted }
        if !conflicted.isEmpty { return .conflicted(candidates: conflicted.map(\.pinned)) }

        let sameAlgorithm = rows.filter { $0.algorithm == presented.algorithm }
        let distinct = Set(sameAlgorithm.map(\.publicKeyBase64))
        // Two different keys for one algorithm: an unresolved sync conflict, even if one of them matches.
        if distinct.count > 1 { return .conflicted(candidates: sameAlgorithm.map(\.pinned)) }
        if distinct.contains(presented.blobBase64) { return .trusted }
        return .mismatch(pinned: (sameAlgorithm.isEmpty ? rows : sameAlgorithm).map(\.pinned))
    }

    public func trust(_ key: HostKey, for endpoint: HostEndpoint, replacing: Bool) async throws {
        let existing = try allRows(for: endpoint)
        let date = now()

        if replacing {
            // The previous pins (of every algorithm) become history on the new record and are deleted,
            // so the deletion syncs and no other device keeps trusting the old key.
            var history: [KnownHostHistoryEntry] = []
            var firstSeen = date
            for row in existing {
                if row.algorithm == key.algorithm, row.publicKeyBase64 == key.blobBase64 {
                    firstSeen = min(firstSeen, row.firstSeenAt)
                    history.append(contentsOf: row.history)
                    continue
                }
                history.append(contentsOf: row.history)
                history.append(KnownHostHistoryEntry(
                    algorithm: row.algorithm, fingerprintSHA256: row.fingerprintSHA256,
                    firstSeenAt: row.firstSeenAt, replacedAt: date
                ))
            }
            for row in existing { modelContext.delete(row) }
            let record = makeRow(key, endpoint: endpoint, at: date)
            record.firstSeenAt = firstSeen
            record.history = Array(Set(history)).sorted { ($0.replacedAt, $0.fingerprintSHA256) < ($1.replacedAt, $1.fingerprintSHA256) }
            modelContext.insert(record)
            try modelContext.save()
            return
        }

        let sameAlgorithm = existing.filter { $0.algorithm == key.algorithm && $0.status != .revoked }
        if let identical = sameAlgorithm.first(where: { $0.publicKeyBase64 == key.blobBase64 }) {
            if identical.status != .trusted { identical.status = .trusted }
            identical.updatedAt = date
            try modelContext.save()
            return
        }
        guard sameAlgorithm.isEmpty else { throw StoreError.differentKeyAlreadyPinned }
        for revoked in existing where revoked.algorithm == key.algorithm && revoked.status == .revoked { modelContext.delete(revoked) }
        modelContext.insert(makeRow(key, endpoint: endpoint, at: date))
        try modelContext.save()
    }

    public func touch(_ endpoint: HostEndpoint) async {
        do {
            let date = now()
            var wrote = false
            for row in try pins(for: endpoint) where date.timeIntervalSince(row.lastSeenAt) >= Self.touchInterval {
                row.lastSeenAt = date
                wrote = true
            }
            if wrote { try modelContext.save() }
        } catch {
            logger.error("Known host touch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Management (Settings > Known Hosts)

    /// Forgets every pin of `endpoint` (the deletion syncs).
    public func forget(_ endpoint: HostEndpoint) async throws {
        for row in try allRows(for: endpoint) { modelContext.delete(row) }
        try modelContext.save()
    }

    /// The pins of `endpoint` that lookups consider.
    public func pinned(for endpoint: HostEndpoint) async -> [PinnedHostKey] {
        ((try? pins(for: endpoint)) ?? []).map(\.pinned)
    }

    // MARK: Helpers

    private func allRows(for endpoint: HostEndpoint) throws -> [KnownHost] {
        let canonical = endpoint.canonical
        return try modelContext.fetch(FetchDescriptor<KnownHost>(predicate: #Predicate { $0.endpoint == canonical }))
    }

    /// Rows lookups consider (everything but revoked), oldest first.
    private func pins(for endpoint: HostEndpoint) throws -> [KnownHost] {
        try allRows(for: endpoint)
            .filter { $0.status != .revoked }
            .sorted { isOlder($0, than: $1, created: \.firstSeenAt, id: \.id) }
    }

    private func makeRow(_ key: HostKey, endpoint: HostEndpoint, at date: Date) -> KnownHost {
        let row = KnownHost(
            endpoint: endpoint.canonical, algorithm: key.algorithm, publicKeyBase64: key.blobBase64,
            fingerprintSHA256: key.fingerprintSHA256, trustedOnDevice: deviceName, sourceRaw: KnownHostSource.tofu.rawValue
        )
        row.createdAt = date
        row.updatedAt = date
        row.firstSeenAt = date
        row.lastSeenAt = date
        return row
    }
}

/// Device facts used to label records.
public enum DeviceInfo {
    /// A human-readable device name (e.g. "MacBook Pro"), without a `.local` suffix.
    public static var name: String {
        #if os(macOS)
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        let raw = ProcessInfo.processInfo.hostName
        #endif
        return raw.hasSuffix(".local") ? String(raw.dropLast(".local".count)) : raw
    }
}
