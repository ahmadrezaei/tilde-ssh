import Foundation
import Testing
import TildeCore
@testable import TildeFeatures

@Suite struct FractionalOrderTests {
    @Test func valueBetweenNeighbours() {
        #expect(FractionalOrder.value(between: nil, and: nil) == 0)
        #expect(FractionalOrder.value(between: 3, and: nil) == 4)
        #expect(FractionalOrder.value(between: nil, and: 3) == 2)
        #expect(FractionalOrder.value(between: 1, and: 2) == 1.5)
    }

    @Test func nextAppends() {
        #expect(FractionalOrder.next(after: []) == 0)
        #expect(FractionalOrder.next(after: [0, 1, 4]) == 5)
    }

    @Test func movingOneRowOnlyRewritesThatRow() {
        let items = [("a", 0.0), ("b", 1.0), ("c", 2.0), ("d", 3.0)].map { (id: $0.0, index: $0.1) }
        // Move "a" to between "c" and "d" (SwiftUI offset 3 = before "d").
        let changes = FractionalOrder.move(items: items, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(changes.count == 1)
        #expect(changes["a"] == 2.5)
    }

    @Test func movingToTheEndsExtendsTheRange() {
        let items = [("a", 0.0), ("b", 1.0), ("c", 2.0)].map { (id: $0.0, index: $0.1) }
        #expect(FractionalOrder.move(items: items, fromOffsets: IndexSet(integer: 2), toOffset: 0)["c"] == -1)
        #expect(FractionalOrder.move(items: items, fromOffsets: IndexSet(integer: 0), toOffset: 3)["a"] == 3)
    }

    @Test func duplicateIndicesRenumberEverything() {
        let items = [("a", 0.0), ("b", 0.0), ("c", 0.0)].map { (id: $0.0, index: $0.1) }
        let changes = FractionalOrder.move(items: items, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(changes == ["c": 0, "a": 1, "b": 2])
    }

    @Test func exhaustedPrecisionRenumbers() {
        let a = 1.0, b = a.nextUp
        let items = [("x", a), ("y", b), ("z", 5.0)].map { (id: $0.0, index: $0.1) }
        let changes = FractionalOrder.move(items: items, fromOffsets: IndexSet(integer: 2), toOffset: 1)
        #expect(changes.count == 3)
        #expect(changes["x"] == 0 && changes["z"] == 1 && changes["y"] == 2)
    }
}

@Suite struct SearchTests {
    private func item(_ name: String, host: String = "10.0.0.1", user: String = "deploy", tags: [String] = [],
                      group: String? = nil, env: ServerEnvironment = .none) -> ServerSearchItem {
        ServerSearchItem(name: name, host: host, username: user, tags: tags, groupName: group, environment: env)
    }

    @Test func fuzzyPrefersPrefixOverSubstringOverSubsequence() throws {
        let prefix = try #require(Fuzzy.score("prod", in: "prod-api"))
        let substring = try #require(Fuzzy.score("api", in: "prod-api"))
        let subsequence = try #require(Fuzzy.score("pda", in: "prod-api"))
        #expect(prefix > substring)
        #expect(substring > subsequence)
        #expect(Fuzzy.score("xyz", in: "prod-api") == nil)
        #expect(Fuzzy.score("", in: "anything") == 0)
    }

    @Test func parsesTagsAndEnvironment() {
        let query = ServerQuery(parsing: "#k8s env:prod api")
        #expect(query.tags == ["k8s"])
        #expect(query.environment == .prod)
        #expect(query.words == ["api"])
        #expect(!query.isEmpty)
        #expect(ServerQuery(parsing: "   ").isEmpty)
    }

    @Test func tagFiltersUseAndLogic() {
        let query = ServerQuery(parsing: "#k8s #edge")
        #expect(query.score(item("a", tags: ["k8s", "edge", "web"])) != nil)
        #expect(query.score(item("b", tags: ["k8s"])) == nil)
    }

    @Test func selectedChipsCombineWithTypedTags() {
        let query = ServerQuery(parsing: "#edge", selectedTags: ["K8S"])
        #expect(query.tags == ["k8s", "edge"])
    }

    @Test func environmentFilterAliases() {
        #expect(ServerQuery(parsing: "env:stg").environment == .staging)
        #expect(ServerQuery(parsing: "env:production").environment == .prod)
        #expect(ServerQuery(parsing: "env:nonsense").environment == nil)
        #expect(ServerQuery(parsing: "env:prod").score(item("a", env: .dev)) == nil)
        #expect(ServerQuery(parsing: "env:prod").score(item("a", env: .prod)) != nil)
    }

    @Test func wordsMatchNameHostUserTagsAndGroup() {
        #expect(ServerQuery(parsing: "db").score(item("db-primary")) != nil)
        #expect(ServerQuery(parsing: "10.0.4").score(item("x", host: "10.0.4.12")) != nil)
        #expect(ServerQuery(parsing: "postgres").score(item("x", user: "postgres")) != nil)
        #expect(ServerQuery(parsing: "edge").score(item("x", tags: ["edge"])) != nil)
        #expect(ServerQuery(parsing: "prod").score(item("x", group: "Production")) != nil)
        #expect(ServerQuery(parsing: "zzz").score(item("db-primary")) == nil)
    }

    @Test func nameMatchesOutrankUserMatches() throws {
        let byName = try #require(ServerQuery(parsing: "deploy").score(item("deploy-box", user: "root")))
        let byUser = try #require(ServerQuery(parsing: "deploy").score(item("other", user: "deploy")))
        #expect(byName > byUser)
    }
}

@Suite struct SSHCommandTests {
    @Test func plainServerOmitsPort22() {
        let server = ServerSnapshot(name: "a", target: ConnectionTarget(host: "10.0.1.12", username: "deploy"))
        #expect(SSHCommand.string(for: server) == "ssh deploy@10.0.1.12")
    }

    @Test func portAndJumpHost() {
        let server = ServerSnapshot(
            name: "a", target: ConnectionTarget(host: "10.0.4.12", port: 2222, username: "deploy"),
            jump: JumpSnapshot(target: ConnectionTarget(host: "bastion.example.com", port: 2200, username: "ops"))
        )
        #expect(SSHCommand.string(for: server) == "ssh -p 2222 -J ops@bastion.example.com:2200 deploy@10.0.4.12")
    }
}

@Suite struct QuickConnectResolverTests {
    private let keyID = UUID()
    private let recordID = UUID()
    private var keys: [QuickConnectKey] { [QuickConnectKey(name: "iphone-ed25519", secretID: keyID, recordID: recordID)] }

    @Test func savedServerWins() {
        let saved = ServerSnapshot(name: "prod", target: ConnectionTarget(host: "Prod.Example.com", username: "deploy"), auth: .password, passwordSecretID: UUID())
        let result = QuickConnectResult(target: ConnectionTarget(host: "prod.example.com", username: "deploy"))
        let resolution = QuickConnectResolver.resolve(result, saved: [saved], keys: keys, defaultKeyRecordID: recordID)
        #expect(resolution.isSaved)
        #expect(resolution.server.id == saved.id)
        #expect(resolution.server.auth == .password)
    }

    @Test func defaultKeyIsUsedWhenNothingMatches() {
        let result = QuickConnectResult(target: ConnectionTarget(host: "new.example.com", username: "root"))
        let resolution = QuickConnectResolver.resolve(result, saved: [], keys: keys, defaultKeyRecordID: recordID)
        #expect(!resolution.isSaved)
        #expect(resolution.server.auth == .key)
        #expect(resolution.server.keyID == keyID)
    }

    @Test func fallsBackToPasswordPrompt() {
        let result = QuickConnectResult(target: ConnectionTarget(host: "new.example.com", port: 2222, username: "root"))
        let resolution = QuickConnectResolver.resolve(result, saved: [], keys: [], defaultKeyRecordID: nil)
        #expect(resolution.server.auth == .passwordPrompt)
        #expect(resolution.server.keyID == nil)
        #expect(resolution.server.name == "new.example.com:2222")
    }

    @Test func dashIKeyNameBeatsTheDefaultKey() {
        let other = QuickConnectKey(name: "work", secretID: UUID(), recordID: UUID())
        let result = QuickConnectResult(target: ConnectionTarget(host: "h", username: "u"), keyName: "work")
        let resolution = QuickConnectResolver.resolve(result, saved: [], keys: keys + [other], defaultKeyRecordID: recordID)
        #expect(resolution.server.keyID == other.secretID)
    }

    @Test func jumpHostComesFromASavedServerWhenPossible() {
        let bastion = ServerSnapshot(name: "bastion", target: ConnectionTarget(host: "bastion", username: "ops"), auth: .key, keyID: keyID)
        let result = QuickConnectResult(
            target: ConnectionTarget(host: "inner", username: "root"),
            jump: ConnectionTarget(host: "bastion", username: "ops")
        )
        let resolution = QuickConnectResolver.resolve(result, saved: [bastion], keys: [], defaultKeyRecordID: nil)
        #expect(resolution.server.jump?.keyID == keyID)
        #expect(resolution.server.jump?.auth == .key)
    }
}

@Suite struct SnippetTemplateTests {
    @Test func findsDistinctPlaceholdersInOrder() {
        #expect(SnippetTemplate.placeholders(in: "sudo journalctl -u <unit> -f --since <since> # <unit>") == ["unit", "since"])
    }

    @Test func ignoresShellRedirectsAndComparisons() {
        #expect(SnippetTemplate.placeholders(in: "cat < input.txt > output.txt").isEmpty)
        #expect(SnippetTemplate.placeholders(in: "echo 1 <2 and 3> 1").isEmpty)
        #expect(SnippetTemplate.placeholders(in: "a <> b").isEmpty)
    }

    @Test func fillReplacesGivenValuesAndKeepsTheRest() {
        let command = "systemctl status <unit> --host <host>"
        #expect(SnippetTemplate.fill(command, values: ["unit": "nginx"]) == "systemctl status nginx --host <host>")
        #expect(SnippetTemplate.fill(command, values: ["unit": "", "host": "db"]) == "systemctl status <unit> --host db")
    }

    @Test func fillReplacesEveryOccurrence() {
        #expect(SnippetTemplate.fill("<a>-<a>", values: ["a": "x"]) == "x-x")
    }
}

@Suite struct SessionErrorCopyTests {
    private let server = ServerSnapshot(name: "prod-api-01", target: ConnectionTarget(host: "10.0.1.12", username: "deploy"))

    @Test func refused() {
        let copy = SessionErrorCopy.present(.refused, server: server)
        #expect(copy.headline == "Connection refused · 10.0.1.12:22")
        #expect(copy.detail == "sshd not running or wrong port.")
        #expect(copy.actions == [.retry, .edit])
    }

    @Test func timeoutAndDNS() {
        #expect(SessionErrorCopy.present(.timeout(seconds: 15), server: server).headline == "No response after 15s · 10.0.1.12:22")
        #expect(SessionErrorCopy.present(.dnsFailure(host: "prod.internal"), server: server).headline == "Can't resolve prod.internal")
    }

    @Test func publicKeyRejectedNamesTheKey() {
        let copy = SessionErrorCopy.present(.authFailed(method: "publickey", serverAllows: ["publickey"]), server: server, keyName: "macbook-ed25519")
        #expect(copy.headline == "Permission denied (publickey)")
        #expect(copy.detail == "Key macbook-ed25519 was rejected. Server accepts: publickey.")
        #expect(copy.actions == [.copyPublicKey, .installKey, .edit])
    }

    @Test func passwordRejectedOffersTryAgain() {
        let copy = SessionErrorCopy.present(.authFailed(method: "password", serverAllows: ["password"]), server: server)
        #expect(copy.headline == "Permission denied (password)")
        #expect(copy.actions == [.tryAgain, .edit])
    }

    @Test func keyboardInteractiveOnly() {
        let copy = SessionErrorCopy.present(.authFailed(method: "publickey", serverAllows: ["keyboard-interactive"]), server: server)
        #expect(copy.headline == "Server only allows keyboard-interactive")
        #expect(copy.detail == "2FA/PAM prompts arrive in v1.1.")
    }

    @Test func missingSecrets() {
        let password = SessionErrorCopy.present(.secretUnavailable(SecretRef(kind: .password, id: UUID())), server: server)
        #expect(password.headline == "Password not on this device yet")
        #expect(password.actions == [.enterOnce, .openSyncSettings])
        let key = SessionErrorCopy.present(.secretUnavailable(SecretRef(kind: .privateKey, id: UUID())), server: server)
        #expect(key.headline == "Key not on this device yet")
    }

    @Test func noCommonAlgorithmListsTheOffer() {
        let copy = SessionErrorCopy.present(.noCommonAlgorithm(kind: "kex", offered: ["diffie-hellman-group1-sha1"]), server: server)
        #expect(copy.headline == "No common algorithm (kex)")
        #expect(copy.detail == "Server offers: diffie-hellman-group1-sha1")
        #expect(copy.actions == [.copyDetails])
    }
}

@Suite struct PaletteRankingTests {
    private func item(_ id: String, _ title: String, section: PaletteItem.Section, subtitle: String? = nil) -> PaletteItem {
        PaletteItem(id: id, kind: .action(.settings), section: section, title: title, subtitle: subtitle, symbol: "x")
    }

    @Test func sectionsKeepTheirOrderAndMatchesRankInside() {
        let candidates = [
            item("act", "New Server", section: .actions),
            item("srv-b", "staging-db", section: .servers),
            item("srv-a", "db-primary", section: .servers),
            item("tab", "db-session", section: .sessions),
        ]
        let ranked = PaletteRanking.rank(candidates, query: "db")
        #expect(ranked.map(\.id) == ["tab", "srv-a", "srv-b"])
    }

    @Test func emptyQueryKeepsInputOrderWithinSections() {
        let candidates = [item("1", "b", section: .servers), item("2", "a", section: .servers), item("3", "z", section: .sessions)]
        #expect(PaletteRanking.rank(candidates, query: "").map(\.id) == ["3", "1", "2"])
    }

    @Test func quickConnectRowAlwaysSurvives() {
        let qc = PaletteItem(id: "qc", kind: .quickConnect(QuickConnectResult(target: ConnectionTarget(host: "h", username: "u"))),
                             section: .connect, title: "Connect to u@h", subtitle: nil, symbol: "return")
        let ranked = PaletteRanking.rank([item("s", "unrelated", section: .servers), qc], query: "u@h")
        #expect(ranked.first?.id == "qc")
    }
}
