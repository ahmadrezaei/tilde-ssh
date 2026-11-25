import Foundation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

@MainActor
@Suite struct ServerRepositoryTests {
    // The suite instance keeps the container alive for the whole test: a ModelContext does not retain it.
    private let container = ModelContainerFactory.preview()
    private var repositories: StoreRepositories { StoreRepositories(container: container) }

    @Test func addNormalizesAndValidates() throws {
        let container = try makeContainer()
        let repo = ServerRepository(context: container.mainContext)
        let server = try repo.add(Server(name: "  ", host: "  Example.COM ", username: "u"))
        #expect(server.host == "example.com")
        #expect(server.name == "example.com", "a blank name falls back to the host")
        #expect(throws: StoreError.self) { try repo.add(Server(name: "x", host: "  ", username: "u")) }
        #expect(throws: StoreError.self) { try repo.add(Server(name: "x", host: "h", port: 70000, username: "u")) }
        #expect(try repo.all().count == 1)
    }

    @Test func lookupById() throws {
        let repo = repositories.servers
        let found = try repo.server(id: PreviewServers.prodAPI.id)
        #expect(found?.name == "prod-api-01")
        #expect(try repo.snapshot(id: PreviewServers.prodAPI.id)?.environment == .prod)
        #expect(try repo.server(id: UUID()) == nil)
    }

    @Test func matchByTarget() throws {
        let repo = repositories.servers
        let hit = try repo.match(ConnectionTarget(host: "10.0.2.5", username: "postgres"))
        #expect(hit?.name == "db-primary")
        #expect(try repo.match(ConnectionTarget(host: "10.0.2.5", port: 2222, username: "postgres")) == nil)
    }

    @Test func deleteReturnsOrphanedSecretsAndCleansScopedSnippets() throws {
        let container = try makeContainer()
        let repositories = StoreRepositories(container: container)
        let secret = UUID()
        let server = Server(name: "s", host: "h", username: "u", authMethodRaw: "password")
        server.passwordSecretID = secret
        try repositories.servers.add(server)
        let scoped = try repositories.snippets.add(name: "scoped", command: "ls", scope: server)
        let global = try repositories.snippets.add(name: "global", command: "pwd")

        let orphaned = try repositories.servers.delete(server)
        #expect(orphaned == [SecretRef(kind: .password, id: secret)])
        #expect(try repositories.servers.all().isEmpty)
        let remaining = try repositories.snippets.all()
        #expect(remaining.map(\.id) == [global.id])
        _ = scoped
    }

    @Test func deletingAJumpHostUnlinksDependents() throws {
        let container = try makeContainer()
        let repo = ServerRepository(context: container.mainContext)
        let bastion = try repo.add(Server(name: "bastion", host: "b", username: "u"))
        let inner = Server(name: "inner", host: "i", username: "u")
        inner.jumpServer = bastion
        try repo.add(inner)
        try repo.delete(bastion)
        #expect(inner.jumpServer == nil)
    }

    @Test func duplicateCopiesSettingsButNotTheSavedPassword() throws {
        let container = try makeContainer()
        let repositories = StoreRepositories(container: container)
        let repo = repositories.servers
        let tag = try repositories.tags.findOrCreate("db")
        let original = Server(name: "db", host: "10.0.0.5", port: 2222, username: "pg", authMethodRaw: "password", environmentRaw: "prod")
        original.passwordSecretID = UUID()
        original.autoTmux = true
        try repo.add(original)
        try repositories.tags.setTags(["db"], on: original)
        let other = try repo.add(Server(name: "other", host: "o", username: "u"))

        let copy = try repo.duplicate(original)
        #expect(copy.name == "db copy" && copy.port == 2222 && copy.environment == .prod && copy.autoTmux)
        #expect(copy.authMethod == .passwordPrompt && copy.passwordSecretID == nil)
        #expect(copy.tagList.map(\.id) == [tag.id])
        #expect(try repo.all().map(\.name) == ["db", "db copy", "other"], "the copy sits right after the original")
        _ = other
    }

    @Test func recordConnectionIsThrottled() throws {
        let container = try makeContainer()
        let repo = ServerRepository(context: container.mainContext)
        let server = try repo.add(Server(name: "s", host: "h", username: "u"))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try repo.recordConnection(server, now: t0))
        #expect(try repo.recordConnection(server, now: t0.addingTimeInterval(60)) == false)
        #expect(server.lastConnectedAt == t0)
        #expect(try repo.recordConnection(server, now: t0.addingTimeInterval(ServerRepository.connectionWriteInterval + 1)))
        #expect(try repo.recentlyConnected().map(\.name) == ["s"])
    }

    @Test func possibleDuplicatesAreFlaggedNotMerged() throws {
        let container = try makeContainer()
        let repo = ServerRepository(context: container.mainContext)
        try repo.add(Server(name: "a", host: "same", username: "u"))
        try repo.add(Server(name: "b", host: "SAME", username: "U"))
        try repo.add(Server(name: "c", host: "different", username: "u"))
        let groups = try repo.possibleDuplicates()
        #expect(groups.count == 1 && groups[0].map(\.name).sorted() == ["a", "b"])
        _ = try Deduplicator.run(in: container.mainContext)
        #expect(try repo.all().count == 3, "servers are never auto-deduplicated")
    }

    @Test func tagsAreCaseInsensitiveAndDeduplicatedPerServer() throws {
        let container = try makeContainer()
        let repositories = StoreRepositories(container: container)
        let server = try repositories.servers.add(Server(name: "s", host: "h", username: "u"))
        try repositories.tags.setTags(["DB", "db", " ", "Edge"], on: server)
        #expect(server.tagList.map(\.name).sorted() == ["DB", "Edge"])
        let again = try repositories.tags.findOrCreate("db")
        #expect(again.name == "DB")
        #expect(try repositories.tags.all().count == 2)
    }

    @Test func deletingAGroupUngroupsItsServers() throws {
        let container = try makeContainer()
        let repositories = StoreRepositories(container: container)
        let group = try repositories.groups.add(name: "G")
        let server = Server(name: "s", host: "h", username: "u")
        server.group = group
        try repositories.servers.add(server)
        try repositories.groups.delete(group)
        #expect(server.group == nil)
        #expect(try repositories.servers.all().count == 1)
    }

    @Test func keyDeletionIsBlockedWhileInUse() throws {
        let container = try makeContainer()
        let repositories = StoreRepositories(container: container)
        let key = try repositories.keys.add(SSHKeyRecord(name: "a", publicKeyOpenSSH: "ssh-ed25519 AAAA", privateSecretID: UUID()), deviceName: "Mac")
        let spare = try repositories.keys.add(SSHKeyRecord(name: "b", publicKeyOpenSSH: "ssh-ed25519 BBBB", privateSecretID: UUID()))
        let server = Server(name: "s", host: "h", username: "u")
        server.key = key
        try repositories.servers.add(server)

        #expect(key.originDeviceName == "Mac")
        #expect(throws: StoreError.keyInUse(serverCount: 1)) { try repositories.keys.delete(key) }
        let secret = try repositories.keys.delete(key, reassigningServersTo: spare)
        #expect(secret == SecretRef(kind: .privateKey, id: key.privateSecretID))
        #expect(server.key?.id == spare.id)
        #expect(try repositories.keys.all().map(\.name) == ["b"])
        #expect(try repositories.keys.record(privateSecretID: spare.privateSecretID)?.name == "b")
    }

    @Test func recentsAreCappedAndCollapsedOnRead() throws {
        let container = try makeContainer()
        let recents = RecentRepository(context: container.mainContext)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<14 { try recents.record(target: "u@h\(index)", at: t0.addingTimeInterval(Double(index))) }
        var list = try recents.recents()
        #expect(list.count == RecentRepository.limit)
        #expect(list.first?.target == "u@h13")

        try recents.record(target: "u@h5", at: t0.addingTimeInterval(100))
        list = try recents.recents()
        #expect(list.first?.target == "u@h5")
        #expect(list.filter { $0.target == "u@h5" }.count == 1)

        // A duplicate target created by another device is collapsed on read.
        container.mainContext.insert(RecentConnection(target: "u@h5", lastUsedAt: t0))
        #expect(try recents.recents().filter { $0.target == "u@h5" }.count == 1)
        #expect(RecentRepository.format(ConnectionTarget(host: "h", port: 2222, username: "u")) == "u@h:2222")
    }

    @Test func storeCounts() throws {
        let counts = try StoreCounts.fetch(in: container.mainContext)
        #expect(counts.servers == PreviewServers.all.count && counts.keys == 1)
    }
}

@MainActor
@Suite struct SearchTests {
    private let container = ModelContainerFactory.preview()
    private func repo() -> ServerRepository { StoreRepositories(container: container).servers }

    @Test func fuzzyScoring() {
        #expect(FuzzyMatcher.score(term: "api", in: "api") == 100)
        #expect(FuzzyMatcher.score(term: "api", in: "api-prod")! > FuzzyMatcher.score(term: "api", in: "prod-api")!)
        #expect(FuzzyMatcher.score(term: "pa1", in: "prod-api-01") != nil, "in-order subsequence")
        #expect(FuzzyMatcher.score(term: "zzz", in: "prod-api-01") == nil)
        #expect(FuzzyMatcher.score(term: "", in: "anything") == 0)
        #expect(FuzzyMatcher.score(term: "z", in: "abc") == nil, "single characters must be a substring")
    }

    @Test func queryParsing() {
        let query = ServerSearchQuery(parsing: "api #K8s  env:prod  env:bogus")
        #expect(query.terms == ["api", "env:bogus"])
        #expect(query.tags == ["k8s"])
        #expect(query.environment == .prod)
        #expect(ServerSearchQuery(parsing: "  ").isEmpty)
        #expect(ServerSearchQuery(parsing: "#").terms == ["#"])
    }

    @Test func emptyQueryReturnsEverythingInOrder() throws {
        let all = try repo().search("")
        #expect(all.count == PreviewServers.all.count)
    }

    @Test func matchesNameHostUserTagAndGroup() throws {
        let repo = repo()
        #expect(try repo.search("prod-api").first?.name == "prod-api-01")
        #expect(try repo.search("10.0.2.5").map(\.name) == ["db-primary"])
        #expect(try repo.search("postgres").map(\.name) == ["db-primary"])
        #expect(try repo.search("edge").map(\.name) == ["prod-api-01"])
        #expect(Set(try repo.search("production").map(\.name)) == ["prod-api-01", "db-primary"])
    }

    @Test func tagAndEnvironmentFilters() throws {
        let repo = repo()
        #expect(try repo.search("#k8s").map(\.name) == ["prod-api-01"])
        #expect(try repo.search("#k").map(\.name) == ["prod-api-01"], "tag filters match by prefix while typing")
        #expect(try repo.search("#k8s #db").isEmpty, "multiple tags are ANDed")
        #expect(Set(try repo.search("env:prod").map(\.name)) == ["prod-api-01", "db-primary"])
        #expect(try repo.search("env:prod #db").map(\.name) == ["db-primary"])
        #expect(try repo.search("env:lab").map(\.name) == ["homelab-pi"])
    }

    @Test func allTermsMustMatchAndBestMatchComesFirst() throws {
        let repo = repo()
        #expect(try repo.search("db primary").map(\.name) == ["db-primary"])
        #expect(try repo.search("db nonsense").isEmpty)
        #expect(try repo.search("staging").first?.name == "staging-web")
    }
}
