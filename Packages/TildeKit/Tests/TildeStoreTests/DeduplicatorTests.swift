import Foundation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

@MainActor
@Suite struct DeduplicatorTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

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

        let report = try Deduplicator.run(in: context)
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
        #expect(try Deduplicator.run(in: context).total == 0)
        #expect(try context.fetchCount(FetchDescriptor<TildeStore.Tag>()) == 2)
    }

    @Test func survivorChoiceIsDeterministicAcrossDevices() throws {
        // Same createdAt on both: the lower UUID wins, no matter the fetch order.
        let container = try makeContainer()
        let context = container.mainContext
        let a = tag("x", age: 0, in: context), b = tag("x", age: 0, in: context)
        let expected = [a, b].min { $0.id.uuidString < $1.id.uuidString }!.id
        try Deduplicator.run(in: context)
        #expect(try context.fetch(FetchDescriptor<TildeStore.Tag>()).map(\.id) == [expected])
    }

    // MARK: Groups

    @Test func emptyGroupsWithTheSameNameMerge() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let g1 = ServerGroup(name: "Prod"), g2 = ServerGroup(name: "Prod")
        g1.createdAt = t0; g2.createdAt = t0.addingTimeInterval(5)
        context.insert(g1); context.insert(g2)
        #expect(try Deduplicator.run(in: context).groupsMerged == 1)
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
        #expect(try Deduplicator.run(in: context).groupsMerged == 0)
    }

    @Test func groupsWithSameNameButDifferentMembersAreKept() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let g1 = ServerGroup(name: "Prod"), g2 = ServerGroup(name: "Prod")
        let s1 = Server(name: "s1", host: "h1", username: "u"), s2 = Server(name: "s2", host: "h2", username: "u")
        s1.group = g1; s2.group = g2
        [g1, g2].forEach(context.insert); [s1, s2].forEach(context.insert)
        try context.save()
        #expect(try Deduplicator.run(in: context).groupsMerged == 0)
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

        let report = try Deduplicator.run(in: context)
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

        let report = try Deduplicator.run(in: context)
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
        try Deduplicator.run(in: context)
        let second = try Deduplicator.run(in: context)
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

        let report = try Deduplicator.run(in: context)
        #expect(report.knownHostConflicts == 0)
        let rows = try context.fetch(FetchDescriptor<KnownHost>())
        #expect(rows.map(\.publicKeyBase64) == ["NEW"] && rows[0].status == .trusted)
    }

    @Test func aConflictResolvedElsewhereIsClearedOnTheLastSurvivor() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let survivor = knownHost("AAAA", in: context)
        survivor.status = .conflicted   // the other candidate was deleted on another device
        try context.save()
        try Deduplicator.run(in: context)
        #expect(survivor.status == .trusted)
    }

    @Test func revokedPinsAreNotTouched() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let revoked = knownHost("AAAA", in: context)
        revoked.status = .revoked
        _ = knownHost("BBBB", in: context)
        #expect(try Deduplicator.run(in: context).total == 0)
        #expect(revoked.status == .revoked)
    }

    @Test func storeLookupSeesTheConflictTheDeduplicatorMarked() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = knownHost("AAAA", endpoint: "10.0.2.5", in: context)
        _ = knownHost("BBBB", endpoint: "10.0.2.5", in: context)
        try Deduplicator.run(in: context)
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

        #expect(try Deduplicator.run(in: context).snippetSeedsMerged == 2)
        let snippets = try context.fetch(FetchDescriptor<Snippet>())
        #expect(snippets.filter { $0.seedID == "seed.htop" }.count == 1)
        #expect(snippets.filter { $0.name == "mine" }.count == 2)
    }

    @Test func coordinatorRunsAfterTheDebounce() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        _ = tag("x", age: 0, in: context); _ = tag("X", age: 1, in: context)
        try context.save()
        let coordinator = DeduplicationCoordinator(container: container, debounce: .milliseconds(20))
        coordinator.schedule()
        coordinator.schedule()   // replaces the pending pass
        try await Task.sleep(for: .milliseconds(300))
        #expect(coordinator.lastReport?.tagsMerged == 1)
        #expect(try context.fetchCount(FetchDescriptor<TildeStore.Tag>()) == 1)
        #expect(coordinator.runNow()?.total == 0)
    }
}
