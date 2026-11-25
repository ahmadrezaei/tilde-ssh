import Foundation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

@MainActor
@Suite struct DeduplicatorTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// Well past the grace period for every record the tests create.
    private var later: Date { t0.addingTimeInterval(7 * 24 * 3600) }

    private func tag(_ name: String, age: TimeInterval, in context: ModelContext) -> TildeStore.Tag {
        let tag = TildeStore.Tag(name: name)
        tag.createdAt = t0.addingTimeInterval(age)
        context.insert(tag)
        return tag
    }

    private func knownHost(_ blob: String, endpoint: String = "h", algorithm: String = "ssh-ed25519", age: TimeInterval = 0, in context: ModelContext) -> KnownHost {
        let host = KnownHost(endpoint: endpoint, algorithm: algorithm, publicKeyBase64: blob, fingerprintSHA256: "SHA256:\(blob)", trustedOnDevice: "d")
        host.firstSeenAt = t0.addingTimeInterval(age)
        host.createdAt = host.firstSeenAt
        context.insert(host)
        return host
    }

    // MARK: Tags

    @Test func tagsWithTheSameNameMergeIntoTheOldestAndKeepEveryServer() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let old = tag("DB", age: 0, in: context)
        let dupe = tag("db", age: 10, in: context)
        let third = tag(" Db ", age: 20, in: context)
        dupe.colorHex = "#fff"
        let a = Server(name: "a", host: "a", username: "u"), b = Server(name: "b", host: "b", username: "u")
        a.tags = [old]
        b.tags = [dupe]
        let both = Server(name: "both", host: "c", username: "u")
        both.tags = [old, third]
        [a, b, both].forEach(context.insert)
        try context.save()

        let report = try Deduplicator.run(in: context, now: later)
        #expect(report.tagsMerged == 2)
        let tags = try context.fetch(FetchDescriptor<TildeStore.Tag>())
        #expect(tags.count == 1 && tags[0].id == old.id)
        #expect(tags[0].colorHex == "#fff", "a color on a duplicate is not lost")
        #expect(Set(tags[0].servers?.map(\.name) ?? []) == ["a", "b", "both"])
        #expect(both.tags?.count == 1)
    }

    @Test func differentTagsAreLeftAlone() throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = tag("db", age: 0, in: context); _ = tag("web", age: 0, in: context)
        #expect(try Deduplicator.run(in: context, now: later).total == 0)
        #expect(try context.fetchCount(FetchDescriptor<TildeStore.Tag>()) == 2)
    }

    @Test func survivorChoiceIsDeterministicAcrossDevices() throws {
        // Same createdAt on both: the lower UUID wins, no matter the fetch order.
        let container = try makeContainer()
        let context = container.mainContext
        let a = tag("x", age: 0, in: context), b = tag("x", age: 0, in: context)
        let expected = [a, b].min { $0.id.uuidString < $1.id.uuidString }!.id
        try Deduplicator.run(in: context, now: later)
        #expect(try context.fetch(FetchDescriptor<TildeStore.Tag>()).map(\.id) == [expected])
    }

    // MARK: Groups

    @Test func emptyGroupsWithTheSameNameMerge() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let g1 = ServerGroup(name: "Prod"), g2 = ServerGroup(name: "Prod")
        g1.createdAt = t0; g2.createdAt = t0.addingTimeInterval(5)
        context.insert(g1); context.insert(g2)
        #expect(try Deduplicator.run(in: context, now: later).groupsMerged == 1)
        #expect(try context.fetch(FetchDescriptor<ServerGroup>()).map(\.id) == [g1.id])
    }

    @Test func aPopulatedGroupAndAnEmptyGroupWithTheSameNameAreKept() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let populated = ServerGroup(name: "Prod"), empty = ServerGroup(name: "Prod")
        let server = Server(name: "s", host: "h", username: "u")
        server.group = populated
        [populated, empty].forEach(context.insert); context.insert(server)
        try context.save()
        #expect(try Deduplicator.run(in: context, now: later).groupsMerged == 0)
    }

    @Test func groupsWithSameNameButDifferentMembersAreKept() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let g1 = ServerGroup(name: "Prod"), g2 = ServerGroup(name: "Prod")
        let s1 = Server(name: "s1", host: "h1", username: "u"), s2 = Server(name: "s2", host: "h2", username: "u")
        s1.group = g1; s2.group = g2
        [g1, g2].forEach(context.insert); [s1, s2].forEach(context.insert)
        try context.save()
        #expect(try Deduplicator.run(in: context, now: later).groupsMerged == 0)
        #expect(try context.fetchCount(FetchDescriptor<ServerGroup>()) == 2)
    }

    // MARK: Known hosts

    @Test func identicalPinsMergeKeepingTheOldest() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let old = knownHost("AAAA", age: 0, in: context)
        let copy = knownHost("AAAA", age: 100, in: context)
        copy.lastSeenAt = t0.addingTimeInterval(500)
        try context.save()

        let report = try Deduplicator.run(in: context, now: later)
        #expect(report.knownHostsMerged == 1 && report.knownHostConflicts == 0)
        let rows = try context.fetch(FetchDescriptor<KnownHost>())
        #expect(rows.map(\.id) == [old.id])
        #expect(rows[0].lastSeenAt == t0.addingTimeInterval(500), "the freshest lastSeenAt survives")
        #expect(rows[0].status == .trusted)
    }

    @Test func differentKeysForTheSameEndpointAndAlgorithmBecomeAConflict() throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = knownHost("AAAA", in: context)
        _ = knownHost("BBBB", in: context)
        _ = knownHost("CCCC", endpoint: "other", in: context)
        _ = knownHost("RSA", algorithm: "ssh-rsa", in: context)
        try context.save()

        let report = try Deduplicator.run(in: context, now: later)
        #expect(report.knownHostConflicts == 2)
        let rows = try context.fetch(FetchDescriptor<KnownHost>())
        #expect(Set(rows.filter { $0.status == .conflicted }.map(\.publicKeyBase64)) == ["AAAA", "BBBB"])
        #expect(rows.filter { $0.status == .trusted }.count == 2, "other endpoints and algorithms are untouched")
        #expect(rows.count == 4, "conflicts are never deleted automatically")
    }

    @Test func conflictHandlingIsIdempotent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = knownHost("AAAA", in: context)
        _ = knownHost("BBBB", in: context)
        try Deduplicator.run(in: context, now: later)
        let second = try Deduplicator.run(in: context, now: later)
        #expect(second.total == 0)
        #expect(try context.fetch(FetchDescriptor<KnownHost>()).allSatisfy { $0.status == .conflicted })
    }

    @Test func aRotatedKeyWhoseDeletionHasNotSyncedIsNotAConflict() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let old = knownHost("OLD", age: 0, in: context)
        let new = knownHost("NEW", age: 100, in: context)
        new.history = [KnownHostHistoryEntry(algorithm: "ssh-ed25519", fingerprintSHA256: old.fingerprintSHA256, firstSeenAt: old.firstSeenAt, replacedAt: t0.addingTimeInterval(100))]
        try context.save()

        let report = try Deduplicator.run(in: context, now: later)
        #expect(report.knownHostConflicts == 0)
        let rows = try context.fetch(FetchDescriptor<KnownHost>())
        #expect(rows.map(\.publicKeyBase64) == ["NEW"] && rows[0].status == .trusted)
    }

    @Test func aConflictIsNeverClearedByTheDeduplicator() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let survivor = knownHost("AAAA", in: context)
        survivor.status = .conflicted   // even if the other candidate was deleted on another device
        try context.save()
        try Deduplicator.run(in: context, now: later)
        #expect(survivor.status == .conflicted, "only trust(replacing: true) clears a conflict")
    }

    @Test func forgettingOneCandidateLeavesTheOtherConflicted() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let a = knownHost("AAAA", in: context)
        let b = knownHost("BBBB", in: context)
        try context.save()
        try Deduplicator.run(in: context, now: later)
        let repo = KnownHostRepository(context: context)
        try repo.forget(a)
        try Deduplicator.run(in: context, now: later)
        #expect(b.status == .conflicted)
        #expect(try repo.conflicts().map(\.publicKeyBase64) == ["BBBB"])
    }

    @Test func mutuallySupersededPinsAreAllKeptAndFlaggedNotDeleted() throws {
        // Device 1 rotated K1 -> K2, device 2 rotated K2 -> K1 at the same time: each row lists the other as history.
        let container = try makeContainer()
        let context = container.mainContext
        let k1 = knownHost("K1", age: 0, in: context)
        let k2 = knownHost("K2", age: 10, in: context)
        k1.history = [KnownHostHistoryEntry(algorithm: "ssh-ed25519", fingerprintSHA256: k2.fingerprintSHA256, firstSeenAt: t0, replacedAt: t0.addingTimeInterval(20))]
        k2.history = [KnownHostHistoryEntry(algorithm: "ssh-ed25519", fingerprintSHA256: k1.fingerprintSHA256, firstSeenAt: t0, replacedAt: t0.addingTimeInterval(20))]
        try context.save()

        let report = try Deduplicator.run(in: context, now: later)
        #expect(report.knownHostConflicts == 2 && report.knownHostsMerged == 0)
        let rows = try context.fetch(FetchDescriptor<KnownHost>())
        #expect(rows.count == 2 && rows.allSatisfy { $0.status == .conflicted })
    }

    @Test func mutuallySupersededPinsLookUpAsConflicted() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let k1 = knownHost("K1", endpoint: "h", age: 0, in: context)
        let k2 = knownHost("K2", endpoint: "h", age: 10, in: context)
        k1.history = [KnownHostHistoryEntry(algorithm: "ssh-ed25519", fingerprintSHA256: k2.fingerprintSHA256, firstSeenAt: t0, replacedAt: t0)]
        k2.history = [KnownHostHistoryEntry(algorithm: "ssh-ed25519", fingerprintSHA256: k1.fingerprintSHA256, firstSeenAt: t0, replacedAt: t0)]
        try context.save()
        try Deduplicator.run(in: context, now: later)
        let store = SwiftDataKnownHostsStore(modelContainer: container, deviceName: "d")
        guard case .conflicted(let candidates) = await store.lookup(HostEndpoint(host: "h"), presented: .sample(blob: "K1")) else {
            Issue.record("expected a conflict, not a first-use prompt"); return
        }
        #expect(candidates.count == 2)
    }

    @Test func rotatingBackToAnEarlierKeyDoesNotMakeItSupersededByItself() async throws {
        let container = try makeContainer()
        let store = SwiftDataKnownHostsStore(modelContainer: container, deviceName: "d")
        let endpoint = HostEndpoint(host: "h")
        let k1 = HostKey.sample(blob: "K1"), k2 = HostKey.sample(blob: "K2")
        try await store.trust(k1, for: endpoint, replacing: false)
        try await store.trust(k2, for: endpoint, replacing: true)
        try await store.trust(k1, for: endpoint, replacing: true)   // K1 -> K2 -> K1

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<KnownHost>())
        #expect(rows.count == 1 && rows[0].publicKeyBase64 == "K1")
        #expect(rows[0].history.map(\.fingerprintSHA256) == ["SHA256:K2"], "its own fingerprint is not in its history")
        #expect(try Deduplicator.run(in: context, now: later).total == 0)
        #expect(await store.lookup(endpoint, presented: k1) == .trusted)
    }

    @Test func revokedPinsAreNotTouched() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let revoked = knownHost("AAAA", in: context)
        revoked.status = .revoked
        _ = knownHost("BBBB", in: context)
        #expect(try Deduplicator.run(in: context, now: later).total == 0)
        #expect(revoked.status == .revoked)
    }

    @Test func storeLookupSeesTheConflictTheDeduplicatorMarked() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = knownHost("AAAA", endpoint: "10.0.2.5", in: context)
        _ = knownHost("BBBB", endpoint: "10.0.2.5", in: context)
        try Deduplicator.run(in: context, now: later)
        let store = SwiftDataKnownHostsStore(modelContainer: container, deviceName: "d")
        guard case .conflicted(let candidates) = await store.lookup(HostEndpoint(host: "10.0.2.5"), presented: .sample(blob: "AAAA")) else {
            Issue.record("expected a conflict"); return
        }
        #expect(candidates.count == 2)
    }

    // MARK: Snippet seeds

    @Test func duplicateSeededSnippetsMergeButUserSnippetsAreKept() throws {
        let container = try makeContainer()
        let context = container.mainContext
        for age in [0.0, 10, 20] {
            let snippet = Snippet(name: "htop", command: "htop", seedID: "seed.htop")
            snippet.createdAt = t0.addingTimeInterval(age)
            context.insert(snippet)
        }
        context.insert(Snippet(name: "mine", command: "ls"))
        context.insert(Snippet(name: "mine", command: "ls"))   // user snippets have no seedID: never merged
        try context.save()

        #expect(try Deduplicator.run(in: context, now: later).snippetSeedsMerged == 2)
        let snippets = try context.fetch(FetchDescriptor<Snippet>())
        #expect(snippets.filter { $0.seedID == "seed.htop" }.count == 1)
        #expect(snippets.filter { $0.name == "mine" }.count == 2)
    }

    @Test func youngTagsAndGroupsAreDeferredNotMerged() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = t0.addingTimeInterval(3600)
        let old = tag("db", age: 0, in: context)
        let fresh = tag("DB", age: 3600 - 60, in: context)   // arrived a minute ago, maybe before its servers
        let g1 = ServerGroup(name: "G"), g2 = ServerGroup(name: "G")
        g1.createdAt = t0; g2.createdAt = now.addingTimeInterval(-30)
        context.insert(g1); context.insert(g2)
        try context.save()

        let first = try Deduplicator.run(in: context, now: now)
        #expect(first.tagsMerged == 0 && first.groupsMerged == 0 && first.deferred == 2)
        #expect(try context.fetchCount(FetchDescriptor<TildeStore.Tag>()) == 2)

        let second = try Deduplicator.run(in: context, now: now.addingTimeInterval(Deduplicator.defaultGracePeriod + 1))
        #expect(second.tagsMerged == 1 && second.groupsMerged == 1 && second.deferred == 0)
        #expect(try context.fetch(FetchDescriptor<TildeStore.Tag>()).map(\.id) == [old.id])
        _ = fresh
    }

    @Test func seedMergeKeepsTheMostRecentlyEditedCopy() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let original = Snippet(name: "htop", command: "htop", seedID: "seed.htop")
        original.createdAt = t0; original.updatedAt = t0
        let edited = Snippet(name: "htop (mine)", command: "htop -t", seedID: "seed.htop")
        edited.createdAt = t0.addingTimeInterval(50); edited.updatedAt = t0.addingTimeInterval(500)
        context.insert(original); context.insert(edited)
        try context.save()
        try Deduplicator.run(in: context, now: later)
        let remaining = try context.fetch(FetchDescriptor<Snippet>())
        #expect(remaining.map(\.name) == ["htop (mine)"])
    }

    @Test func coordinatorRunsAfterTheDebounce() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = tag("x", age: -1_000_000_000, in: context); _ = tag("X", age: -999_999_999, in: context)   // long in the past
        try context.save()
        let coordinator = DeduplicationCoordinator(container: container, debounce: .milliseconds(20), gracePeriod: 0)
        coordinator.schedule()
        coordinator.schedule()   // replaces the pending pass
        try await Task.sleep(for: .milliseconds(300))
        #expect(coordinator.lastReport?.tagsMerged == 1)
        #expect(try context.fetchCount(FetchDescriptor<TildeStore.Tag>()) == 1)
        #expect(coordinator.runNow()?.total == 0)
    }
}
