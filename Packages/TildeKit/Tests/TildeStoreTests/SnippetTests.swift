import Foundation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

@MainActor
@Suite struct SnippetTests {
    @Test func seedsMatchTheDesignExamples() {
        #expect(SnippetSeeds.all.count == 8)
        #expect(Set(SnippetSeeds.all.map(\.seedID)).count == 8)
        // The seeded names and commands equal the mock provider's list that other workstreams build against.
        let mock = StaticSnippetProvider.seeded
        #expect(SnippetSeeds.all.map(\.name) == mock.map(\.name))
        #expect(SnippetSeeds.all.map(\.command) == mock.map(\.command))
        #expect(SnippetSeeds.all.map { $0.runMode == .insertAndReturn } == mock.map(\.runOnInsert))
    }

    @Test func seedingIsIdempotentAndOnlyAddsMissingOnes() throws {
        let container = try makeContainer()
        let context = container.mainContext
        #expect(try SnippetSeeds.seedMissing(in: context) == 8)
        #expect(try SnippetSeeds.seedMissing(in: context) == 0)
        let htop = try context.fetch(FetchDescriptor<Snippet>()).first { $0.seedID == "seed.htop" }!
        context.delete(htop)
        #expect(try SnippetSeeds.seedMissing(in: context) == 1)
        #expect(try context.fetchCount(FetchDescriptor<Snippet>()) == 8)
    }

    @Test func seedIfNeededRunsOncePerDeviceSoDeletedSeedsStayDeleted() throws {
        let defaults = UserDefaults(suiteName: "tilde.tests.\(UUID().uuidString)")!
        let container = try makeContainer()
        let context = container.mainContext
        #expect(try SnippetSeeds.seedIfNeeded(in: context, defaults: defaults) == 8)
        for snippet in try context.fetch(FetchDescriptor<Snippet>()) { context.delete(snippet) }
        try context.save()
        #expect(try SnippetSeeds.seedIfNeeded(in: context, defaults: defaults) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Snippet>()) == 0)
    }

    @Test func providerReturnsSeededSnippetsInOrder() async throws {
        let container = try makeContainer()
        try SnippetSeeds.seedMissing(in: container.mainContext)
        let provider = SwiftDataSnippetProvider(container: container)
        let all = await provider.snippets(matching: "")
        #expect(all.map(\.name) == SnippetSeeds.all.map(\.name))
        #expect(all.first { $0.name == "kubectl pods" }?.runOnInsert == true)
        #expect(all.first { $0.name == "service status" }?.runOnInsert == false)
    }

    @Test func providerSearchesNameCommandAndFolderBestFirst() async throws {
        let container = try makeContainer()
        try SnippetSeeds.seedMissing(in: container.mainContext)
        let provider = SwiftDataSnippetProvider(container: container)
        #expect(await provider.snippets(matching: "kubectl").map(\.name) == ["kubectl pods"])
        #expect(await provider.snippets(matching: "  DOCKER ").map(\.name) == ["docker ps"])
        #expect(await provider.snippets(matching: "ss -tulpn").map(\.name) == ["listening ports"], "matches the command text")
        #expect(await provider.snippets(matching: "logs").map(\.name).sorted() == ["journalctl follow", "tail syslog"], "matches the folder")
        #expect(await provider.snippets(matching: "disk memory").map(\.name) == ["disk and memory"], "all terms must match")
        #expect(await provider.snippets(matching: "no-such-thing").isEmpty)
        // A name match outranks a command-only match.
        let repo = SnippetRepository(context: container.mainContext)
        try repo.add(name: "network check", command: "htop is great")
        #expect(await provider.snippets(matching: "htop").first?.name == "htop")
    }

    @Test func snapshotsUseTheModelIDAndSeeFreshData() async throws {
        let container = try makeContainer()
        let repo = SnippetRepository(context: container.mainContext)
        let provider = SwiftDataSnippetProvider(container: container)
        #expect(await provider.snippets(matching: "").isEmpty)
        let snippet = try repo.add(name: "uptime", command: "uptime", runMode: .insertAndReturn)
        let found = await provider.snippets(matching: "up")
        #expect(found.map(\.id) == [snippet.id] && found[0].runOnInsert)
        try repo.delete(snippet)
        #expect(await provider.snippets(matching: "up").isEmpty)
    }

    @Test func serverScopedSnippetsOnlyShowForThatServer() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let servers = ServerRepository(context: context)
        let repo = SnippetRepository(context: context)
        let a = try servers.add(Server(name: "a", host: "a", username: "u"))
        let b = try servers.add(Server(name: "b", host: "b", username: "u"))
        try repo.add(name: "global", command: "g")
        try repo.add(name: "only-a", command: "a-cmd", scope: a)
        let provider = SwiftDataSnippetProvider(container: container)

        #expect(await provider.snippets(matching: "").map(\.name) == ["global"])
        #expect(await provider.snippets(matching: "", forServer: a.id).map(\.name) == ["global", "only-a"])
        #expect(await provider.snippets(matching: "", forServer: b.id).map(\.name) == ["global"])
        #expect(try repo.all(scope: a).count == 2 && repo.all().count == 1)
    }

    @Test func repositorySearchAndValidation() throws {
        let container = try makeContainer()
        let repo = SnippetRepository(context: container.mainContext)
        try SnippetSeeds.seedMissing(in: container.mainContext)
        #expect(try repo.search("kube").map(\.name) == ["kubectl pods"])
        #expect(try repo.search("").count == 8)
        #expect(throws: StoreError.self) { try repo.add(name: "x", command: "") }
        #expect(try repo.add(name: " ", command: "ls -la").name == "ls -la", "a blank name falls back to the command")
    }

    @Test func providerConformsToTheContractAndIsSendable() {
        let container = ModelContainerFactory.preview()
        let provider: any SnippetProviding = SwiftDataSnippetProvider(container: container)
        let sendable: any Sendable = provider
        _ = sendable
    }
}
