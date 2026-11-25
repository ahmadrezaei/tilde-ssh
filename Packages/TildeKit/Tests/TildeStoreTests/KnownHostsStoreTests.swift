import Foundation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

@Suite struct KnownHostsStoreTests {
    private let endpoint = HostEndpoint(host: "10.0.2.5")
    private let clock = TestClock()

    private func makeStore(_ container: ModelContainer? = nil, device: String = "Test Mac") throws -> (SwiftDataKnownHostsStore, ModelContainer) {
        let container = try container ?? makeContainer()
        let clock = self.clock
        return (SwiftDataKnownHostsStore(modelContainer: container, deviceName: device, now: { clock.now }), container)
    }

    private func rows(_ container: ModelContainer) throws -> [KnownHost] {
        try ModelContext(container).fetch(FetchDescriptor<KnownHost>())
    }

    @Test func unknownThenTrustedThenMismatch() async throws {
        let (store, _) = try makeStore()
        let key = HostKey.sample()
        #expect(await store.lookup(endpoint, presented: key) == .unknown)

        try await store.trust(key, for: endpoint, replacing: false)
        #expect(await store.lookup(endpoint, presented: key) == .trusted)

        let other = HostKey.sample(blob: "BBBB")
        guard case .mismatch(let pinned) = await store.lookup(endpoint, presented: other) else {
            Issue.record("expected a mismatch"); return
        }
        #expect(pinned.map(\.key) == [key])
        #expect(pinned.first?.trustedOnDevice == "Test Mac")
    }

    @Test func pinsAreScopedToTheEndpoint() async throws {
        let (store, _) = try makeStore()
        let key = HostKey.sample()
        try await store.trust(key, for: endpoint, replacing: false)
        #expect(await store.lookup(HostEndpoint(host: "10.0.2.5", port: 2222), presented: key) == .unknown)
        #expect(await store.lookup(HostEndpoint(host: "10.0.2.6"), presented: key) == .unknown)
        // Hostnames are case-insensitive, as in known_hosts.
        try await store.trust(key, for: HostEndpoint(host: "DB.Example.com", port: 2222), replacing: false)
        #expect(await store.lookup(HostEndpoint(host: "db.example.com", port: 2222), presented: key) == .trusted)
    }

    @Test func differentAlgorithmIsAMismatchLikeTheMock() async throws {
        let (store, _) = try makeStore()
        let ed = HostKey.sample("ssh-ed25519", blob: "AAAA")
        try await store.trust(ed, for: endpoint, replacing: false)
        let rsa = HostKey.sample("ssh-rsa", blob: "RSA1")
        guard case .mismatch(let pinned) = await store.lookup(endpoint, presented: rsa) else {
            Issue.record("expected a mismatch"); return
        }
        #expect(pinned.map(\.key) == [ed])
        // Once both are pinned, each one is trusted.
        try await store.trust(rsa, for: endpoint, replacing: false)
        #expect(await store.lookup(endpoint, presented: rsa) == .trusted)
        #expect(await store.lookup(endpoint, presented: ed) == .trusted)
    }

    @Test func trustingTheSameKeyTwiceIsIdempotent() async throws {
        let (store, container) = try makeStore()
        let key = HostKey.sample()
        try await store.trust(key, for: endpoint, replacing: false)
        try await store.trust(key, for: endpoint, replacing: false)
        #expect(try rows(container).count == 1)
    }

    @Test func pinningASecondKeyForTheSameAlgorithmWithoutReplacingThrows() async throws {
        let (store, container) = try makeStore()
        try await store.trust(.sample(blob: "AAAA"), for: endpoint, replacing: false)
        await #expect(throws: StoreError.differentKeyAlreadyPinned) {
            try await store.trust(.sample(blob: "BBBB"), for: endpoint, replacing: false)
        }
        #expect(try rows(container).count == 1)
    }

    @Test func replacingRecordsHistoryAndRemovesTheOldPin() async throws {
        let (store, container) = try makeStore()
        let old = HostKey.sample(blob: "OLD", fingerprint: "SHA256:old")
        let new = HostKey.sample(blob: "NEW", fingerprint: "SHA256:new")
        try await store.trust(old, for: endpoint, replacing: false)
        clock.advance(3600)
        try await store.trust(new, for: endpoint, replacing: true)

        let stored = try rows(container)
        #expect(stored.count == 1)
        let row = try #require(stored.first)
        #expect(row.fingerprintSHA256 == "SHA256:new")
        #expect(row.history.map(\.fingerprintSHA256) == ["SHA256:old"])
        #expect(row.history.first?.replacedAt == clock.now)
        #expect(await store.lookup(endpoint, presented: new) == .trusted)
        guard case .mismatch = await store.lookup(endpoint, presented: old) else {
            Issue.record("the old key must now be a mismatch"); return
        }

        // A second rotation keeps the whole chain.
        try await store.trust(.sample(blob: "NEWER", fingerprint: "SHA256:newer"), for: endpoint, replacing: true)
        #expect(try rows(container).first?.history.map(\.fingerprintSHA256).sorted() == ["SHA256:new", "SHA256:old"])
    }

    @Test func replacingWithTheSameKeyKeepsItsFirstSeenDate() async throws {
        let (store, container) = try makeStore()
        let key = HostKey.sample()
        try await store.trust(key, for: endpoint, replacing: false)
        let first = try #require(try rows(container).first?.firstSeenAt)
        clock.advance(86_400)
        try await store.trust(key, for: endpoint, replacing: true)
        #expect(try rows(container).count == 1)
        #expect(try rows(container).first?.firstSeenAt == first)
        #expect(try rows(container).first?.history.isEmpty == true)
    }

    @Test func conflictedPinsAreReportedAndOnlyReplacingResolvesThem() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        for (blob, device) in [("AAAA", "iPhone"), ("BBBB", "MacBook")] {
            let host = KnownHost(endpoint: endpoint.canonical, algorithm: "ssh-ed25519", publicKeyBase64: blob, fingerprintSHA256: "SHA256:\(blob)", trustedOnDevice: device)
            host.status = .conflicted
            context.insert(host)
        }
        try context.save()

        // Even the key that matches one candidate is reported as a conflict: it is never auto-resolved.
        guard case .conflicted(let candidates) = await store.lookup(endpoint, presented: .sample(blob: "AAAA")) else {
            Issue.record("expected a conflict"); return
        }
        #expect(Set(candidates.map(\.trustedOnDevice)) == ["iPhone", "MacBook"])
        guard case .conflicted = await store.lookup(endpoint, presented: .sample(blob: "CCCC")) else {
            Issue.record("expected a conflict"); return
        }

        try await store.trust(.sample(blob: "AAAA"), for: endpoint, replacing: true)
        #expect(await store.lookup(endpoint, presented: .sample(blob: "AAAA")) == .trusted)
        #expect(try rows(container).count == 1)
    }

    @Test func unsyncedDivergentPinsCountAsAConflictBeforeTheDeduplicatorRuns() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        for blob in ["AAAA", "BBBB"] {
            context.insert(KnownHost(endpoint: endpoint.canonical, algorithm: "ssh-ed25519", publicKeyBase64: blob, fingerprintSHA256: "SHA256:\(blob)", trustedOnDevice: "d"))
        }
        try context.save()
        guard case .conflicted(let candidates) = await store.lookup(endpoint, presented: .sample(blob: "AAAA")) else {
            Issue.record("expected a conflict"); return
        }
        #expect(candidates.count == 2)
    }

    @Test func revokedPinsAreIgnored() async throws {
        let (store, container) = try makeStore()
        let context = ModelContext(container)
        let revoked = KnownHost(endpoint: endpoint.canonical, algorithm: "ssh-ed25519", publicKeyBase64: "AAAA", fingerprintSHA256: "SHA256:AAAA", trustedOnDevice: "d")
        revoked.status = .revoked
        context.insert(revoked)
        try context.save()
        #expect(await store.lookup(endpoint, presented: .sample(blob: "AAAA")) == .unknown)
        try await store.trust(.sample(blob: "BBBB"), for: endpoint, replacing: false)
        #expect(await store.lookup(endpoint, presented: .sample(blob: "BBBB")) == .trusted)
    }

    @Test func touchIsThrottledToOncePerDay() async throws {
        let (store, container) = try makeStore()
        try await store.trust(.sample(), for: endpoint, replacing: false)
        let created = clock.now

        clock.advance(3600)
        await store.touch(endpoint)
        #expect(try rows(container).first?.lastSeenAt == created, "within a day: no write")

        clock.advance(24 * 3600)
        await store.touch(endpoint)
        #expect(try rows(container).first?.lastSeenAt == clock.now)

        let stamp = clock.now
        clock.advance(60)
        await store.touch(endpoint)
        #expect(try rows(container).first?.lastSeenAt == stamp)
        await store.touch(HostEndpoint(host: "never-seen"))   // no pin: a no-op, not a crash
    }

    @Test func pinsSurviveANewStoreInstanceAndAreSharedAcrossActors() async throws {
        let container = try makeContainer()
        let (first, _) = try makeStore(container, device: "iPhone")
        try await first.trust(.sample(), for: endpoint, replacing: false)
        let (second, _) = try makeStore(container, device: "iPad")
        #expect(await second.lookup(endpoint, presented: .sample()) == .trusted)
        #expect(await second.pinned(for: endpoint).first?.trustedOnDevice == "iPhone")
    }

    @Test func manyConcurrentLookupsAndWritesFromOtherTasks() async throws {
        let (store, _) = try makeStore()
        try await store.trust(.sample(), for: endpoint, replacing: false)
        let endpoint = endpoint
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<40 {
                group.addTask {
                    if index.isMultiple(of: 4) { await store.touch(endpoint) }
                    return await store.lookup(endpoint, presented: .sample()) == .trusted
                }
            }
            for await ok in group { #expect(ok) }
        }
    }

    @Test func forgetRemovesEveryPinOfTheEndpoint() async throws {
        let (store, container) = try makeStore()
        try await store.trust(.sample("ssh-ed25519", blob: "AAAA"), for: endpoint, replacing: false)
        try await store.trust(.sample("ssh-rsa", blob: "RSA"), for: endpoint, replacing: false)
        try await store.forget(endpoint)
        #expect(try rows(container).isEmpty)
        #expect(await store.lookup(endpoint, presented: .sample()) == .unknown)
    }

    @MainActor
    @Test func repositoryListsForgetsAndImports() throws {
        let container = try makeContainer()
        let repo = KnownHostRepository(context: container.mainContext)
        let entries: [(endpoint: HostEndpoint, key: HostKey)] = [
            (HostEndpoint(host: "b.example.com"), .sample(blob: "BBBB")),
            (HostEndpoint(host: "a.example.com", port: 2222), .sample(blob: "AAAA")),
        ]
        #expect(try repo.importPins(entries, deviceName: "Mac") == 2)
        #expect(try repo.importPins(entries, deviceName: "Mac") == 0, "importing twice adds nothing")
        // A different key for a known endpoint and algorithm is never silently replaced.
        #expect(try repo.importPins([(HostEndpoint(host: "b.example.com"), .sample(blob: "EVIL"))], deviceName: "Mac") == 0)
        let all = try repo.all()
        #expect(all.map(\.endpoint) == ["[a.example.com]:2222", "b.example.com"])
        #expect(all.allSatisfy { $0.source == .imported })
        try repo.forget(all[0])
        try repo.forget(endpoint: HostEndpoint(host: "b.example.com"))
        #expect(try repo.all().isEmpty)
    }

    @Test func storeConformsToTheContract() {
        func accepts(_ store: any KnownHostsStore) {}
        let container = try! makeContainer()
        accepts(SwiftDataKnownHostsStore(modelContainer: container))
    }
}
