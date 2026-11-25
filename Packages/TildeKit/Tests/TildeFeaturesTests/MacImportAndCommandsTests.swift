import Foundation
import Testing
import TildeCore
@testable import TildeFeatures

// Tests for the Mac glue in `TildeFeatures/Mac`: menu helpers, `~/.ssh/config` and `known_hosts` import, URL links.

private let ed25519Blob = "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
private let ed25519Fingerprint = "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
private let ecdsaBlob = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBD95RCw+7kRQ9xOg4V6n8dcSriSqxdfPuqzfOPjbitJhq+rsakTOO9kIRoi1qjPwSmvN37nzAU8fslxTy6SRb/8="

@Suite struct TabShortcutTests {
    @Test func digitsMapToZeroBasedIndexes() {
        #expect(TabShortcut.index(forDigit: 1, tabCount: 3) == 0)
        #expect(TabShortcut.index(forDigit: 3, tabCount: 3) == 2)
        #expect(TabShortcut.index(forDigit: 4, tabCount: 3) == nil)
    }

    @Test func nineSelectsTheLastTab() {
        #expect(TabShortcut.index(forDigit: 9, tabCount: 4) == 3)
        #expect(TabShortcut.index(forDigit: 9, tabCount: 12) == 11)
        #expect(TabShortcut.index(forDigit: 9, tabCount: 0) == nil)
    }

    @Test func outOfRangeDigits() {
        #expect(TabShortcut.index(forDigit: 0, tabCount: 3) == nil)
        #expect(TabShortcut.index(forDigit: 10, tabCount: 3) == nil)
    }

    @Test func neighbourWraps() {
        #expect(TabShortcut.neighbour(of: 2, count: 3, forward: true) == 0)
        #expect(TabShortcut.neighbour(of: 0, count: 3, forward: false) == 2)
        #expect(TabShortcut.neighbour(of: nil, count: 3, forward: true) == 0)
        #expect(TabShortcut.neighbour(of: nil, count: 3, forward: false) == 2)
        #expect(TabShortcut.neighbour(of: 0, count: 0, forward: true) == nil)
    }
}

@Suite struct SSHConfigImportPlannerTests {
    private let hosts = [
        SSHConfigHost(alias: "prod-api", hostName: "10.0.1.12", user: "deploy", identityFiles: ["~/.ssh/id_ed25519"], proxyJump: "bastion"),
        SSHConfigHost(alias: "bastion", hostName: "bastion.example.com", user: "ops", port: 2222),
        SSHConfigHost(alias: "*"),
        SSHConfigHost(alias: "*.internal", user: "root"),
        SSHConfigHost(alias: "nohostname"),
        SSHConfigHost(alias: "deep", hostName: "10.9.9.9", proxyJump: "a, b"),
        SSHConfigHost(alias: "elsewhere", hostName: "10.9.9.8", proxyJump: "ops@gate.example.com:2200"),
        SSHConfigHost(alias: "direct", hostName: "10.9.9.7", proxyJump: "none"),
    ]

    @Test func skipsWildcardPatterns() {
        let plan = SSHConfigImportPlanner.plan(hosts: hosts, existing: [])
        #expect(plan.skippedPatterns == ["*", "*.internal"])
        #expect(plan.rows.map(\.host.alias) == ["prod-api", "bastion", "nohostname", "deep", "elsewhere", "direct"])
    }

    @Test func fillsInHostAndPortDefaults() throws {
        let plan = SSHConfigImportPlanner.plan(hosts: hosts, existing: [])
        let bare = try #require(plan.rows.first { $0.host.alias == "nohostname" })
        #expect(bare.displayHost == "nohostname")
        #expect(bare.host.hostName == "nohostname")
        #expect(bare.port == 22)
        let bastion = try #require(plan.rows.first { $0.host.alias == "bastion" })
        #expect(bastion.port == 2222)
        #expect(bastion.summary == "ops@bastion.example.com:2222")
    }

    @Test func classifiesProxyJump() throws {
        let plan = SSHConfigImportPlanner.plan(hosts: hosts, existing: [])
        func row(_ alias: String) throws -> SSHConfigImportRow { try #require(plan.rows.first { $0.host.alias == alias }) }
        #expect(try row("prod-api").jump == .single("bastion", inConfig: true))
        #expect(try row("elsewhere").jump == .single("ops@gate.example.com:2200", inConfig: false))
        #expect(try row("deep").jump == .multiHop(["a", "b"]))
        #expect(try row("direct").jump == SSHConfigJump.none)
        // Multi-hop chains import without a jump host; single hops keep theirs.
        #expect(try row("deep").host.proxyJump == nil)
        #expect(try row("prod-api").host.proxyJump == "bastion")
    }

    @Test func flagsServersThatAlreadyExist() throws {
        let existing = [
            ServerSnapshot(name: "my-bastion", target: ConnectionTarget(host: "Bastion.Example.com", port: 2222, username: "ops")),
            ServerSnapshot(name: "prod-api", target: ConnectionTarget(host: "other.example.com", username: "deploy")),
        ]
        let plan = SSHConfigImportPlanner.plan(hosts: hosts, existing: existing)
        let bastion = try #require(plan.rows.first { $0.host.alias == "bastion" })
        #expect(bastion.conflict == .sameTarget(serverName: "my-bastion"))
        let prod = try #require(plan.rows.first { $0.host.alias == "prod-api" })
        #expect(prod.conflict == .sameName(serverName: "prod-api"))
        let direct = try #require(plan.rows.first { $0.host.alias == "direct" })
        #expect(direct.conflict == nil)
    }

    @Test func differentUserOnSameHostIsNotAConflict() {
        let existing = [ServerSnapshot(name: "x", target: ConnectionTarget(host: "10.9.9.7", username: "someone-else"))]
        let host = SSHConfigHost(alias: "direct", hostName: "10.9.9.7", user: "deploy")
        let plan = SSHConfigImportPlanner.plan(hosts: [host], existing: existing)
        #expect(plan.rows.first?.conflict == nil)
    }

    @Test func bareHostExtraction() {
        #expect(SSHConfigImportPlanner.bareHost(of: "bastion") == "bastion")
        #expect(SSHConfigImportPlanner.bareHost(of: "ops@bastion:2200") == "bastion")
        #expect(SSHConfigImportPlanner.bareHost(of: "ssh://ops@bastion:2200") == "bastion")
        #expect(SSHConfigImportPlanner.bareHost(of: "[::1]:22") == "::1")
    }
}

@MainActor
@Suite struct SSHConfigImportModelTests {
    private func model(existing: [ServerSnapshot] = []) -> SSHConfigImportModel {
        let parser = FakeSSHConfigParser(hosts: [
            SSHConfigHost(alias: "prod-api", hostName: "10.0.1.12", user: "deploy", identityFiles: ["~/.ssh/id_ed25519", "~/.ssh/id_ed25519"], proxyJump: "bastion"),
            SSHConfigHost(alias: "bastion", hostName: "bastion.example.com", user: "ops", port: 2222, identityFiles: ["~/.ssh/id_work"]),
            SSHConfigHost(alias: "lab", hostName: "10.0.0.9", identityFiles: ["none"]),
        ])
        return SSHConfigImportModel(parser: parser, existing: existing)
    }

    @Test func checksEverythingExceptDuplicates() {
        let existing = [ServerSnapshot(name: "b", target: ConnectionTarget(host: "bastion.example.com", port: 2222, username: "ops"))]
        let model = model(existing: existing)
        model.load(text: "ignored", sourceName: "config")
        #expect(model.plan.rows.count == 3)
        #expect(model.selectedHosts.map(\.alias) == ["prod-api", "lab"])
    }

    @Test func collectsUniqueIdentityFilesOfCheckedRows() {
        let model = model()
        model.load(text: "ignored", sourceName: "config")
        #expect(model.requestedIdentityFiles == ["~/.ssh/id_ed25519", "~/.ssh/id_work"])
        model.selection = [0]
        #expect(model.requestedIdentityFiles == ["~/.ssh/id_ed25519"])
    }

    @Test func warnsWhenAJumpHostIsNotChecked() {
        let model = model()
        model.load(text: "ignored", sourceName: "config")
        #expect(model.unselectedJumpAliases.isEmpty)
        model.selection = [0]
        #expect(model.unselectedJumpAliases == ["bastion"])
    }

    @Test func matchesPickedKeyFilesToConfigPaths() {
        let model = model()
        model.load(text: "ignored", sourceName: "config")
        model.addKeyFiles([("id_work", Data("k".utf8)), ("id_work", Data("again".utf8))])
        #expect(model.keyFiles.count == 1)
        #expect(model.keyFiles.first?.configPaths == ["~/.ssh/id_work"])
    }

    @Test func emptyConfigReportsAnError() {
        let model = SSHConfigImportModel(parser: FakeSSHConfigParser(hosts: [SSHConfigHost(alias: "*")]))
        model.load(text: "Host *", sourceName: "config")
        #expect(model.plan.rows.isEmpty)
        #expect(model.errorMessage != nil)
        #expect(!model.canImport)
    }
}

@Suite struct KnownHostsParserTests {
    @Test func parsesPlainBracketedAndMultiHostLines() {
        let text = """
        # a comment

        example.com ssh-ed25519 \(ed25519Blob) root@example
        [10.0.2.5]:2222 ssh-ed25519 \(ed25519Blob)
        a.example.com,192.0.2.7 ssh-ed25519 \(ed25519Blob)
        [2001:db8::1]:2200 ecdsa-sha2-nistp256 \(ecdsaBlob)
        2001:db8::2 ecdsa-sha2-nistp256 \(ecdsaBlob)
        """
        let result = KnownHostsParser.parse(text)
        let endpoints = result.entries.map(\.endpoint)
        #expect(endpoints == [
            HostEndpoint(host: "example.com", port: 22),
            HostEndpoint(host: "10.0.2.5", port: 2222),
            HostEndpoint(host: "a.example.com", port: 22),
            HostEndpoint(host: "192.0.2.7", port: 22),
            HostEndpoint(host: "2001:db8::1", port: 2200),
            HostEndpoint(host: "2001:db8::2", port: 22),
        ])
        #expect(result.skipped.isEmpty)
        #expect(result.entries.first?.key.fingerprintSHA256 == ed25519Fingerprint)
        #expect(result.entries.first?.line == 3)
        // Entries from the same line share the line number.
        #expect(result.entries[2].line == result.entries[3].line)
    }

    @Test func skipsHashedEntriesAndCountsThem() {
        let text = """
        |1|F1E1KeoE/eEWhi10WpGv4OdiO6Y=|3988QV0VbkuUlFskmfOfUZhJKxE= ssh-ed25519 \(ed25519Blob)
        |1|aaaaaaaaaaaaaaaaaaaaaaaaaaa=|bbbbbbbbbbbbbbbbbbbbbbbbbbb= ssh-ed25519 \(ed25519Blob)
        example.com ssh-ed25519 \(ed25519Blob)
        """
        let result = KnownHostsParser.parse(text)
        #expect(result.entries.count == 1)
        #expect(result.hashedCount == 2)
    }

    @Test func skipsWildcardsMarkersAndUnsupportedKeys() {
        let text = """
        *.example.com ssh-ed25519 \(ed25519Blob)
        @cert-authority *.corp ssh-ed25519 \(ed25519Blob)
        @revoked old.example.com ssh-ed25519 \(ed25519Blob)
        legacy.example.com ssh-dss AAAAB3NzaC1kc3MAAAA=
        """
        let result = KnownHostsParser.parse(text)
        #expect(result.entries.isEmpty)
        #expect(result.skipped.count == 4)
        #expect(result.skipped.contains { $0.reason == .wildcardPattern("*.example.com") })
        #expect(result.skipped.contains { $0.reason == .marker("@cert-authority") })
        #expect(result.skipped.contains { $0.reason == .unsupportedAlgorithm("ssh-dss") })
    }

    @Test func rejectsKeysWhoseBlobDoesNotMatchTheirType() {
        let text = """
        a.example.com ssh-ed25519 not-base64!!
        b.example.com ssh-rsa \(ed25519Blob)
        c.example.com ssh-ed25519
        """
        let result = KnownHostsParser.parse(text)
        #expect(result.entries.isEmpty)
        #expect(result.skipped.map(\.reason) == [.malformed, .malformed, .malformed])
    }

    @Test func dropsDuplicateEntries() {
        let text = """
        example.com ssh-ed25519 \(ed25519Blob)
        EXAMPLE.com ssh-ed25519 \(ed25519Blob)
        """
        // Host names are case-insensitive: the second line pins the same endpoint and key.
        #expect(KnownHostsParser.parse(text).entries.count == 1)
    }
}

@MainActor
@Suite struct KnownHostsImportModelTests {
    private func key(_ blob: String, algorithm: String = "ssh-ed25519") -> HostKey {
        HostKey(algorithm: algorithm, blobBase64: blob, fingerprintSHA256: "SHA256:test")
    }

    @Test func classifiesAgainstExistingPins() async {
        let other = ed25519Blob.dropLast(2) + "xx"
        let store = InMemoryKnownHostsStore(pins: [
            HostEndpoint(host: "same.example.com"): [key(ed25519Blob)],
            HostEndpoint(host: "changed.example.com"): [key(String(other))],
        ])
        let model = KnownHostsImportModel()
        model.load(text: """
        new.example.com ssh-ed25519 \(ed25519Blob)
        same.example.com ssh-ed25519 \(ed25519Blob)
        changed.example.com ssh-ed25519 \(ed25519Blob)
        """, sourceName: "known_hosts")
        await model.classify(using: store)

        #expect(model.entries(.new).map(\.endpoint.host) == ["new.example.com"])
        #expect(model.entries(.alreadyTrusted).map(\.endpoint.host) == ["same.example.com"])
        #expect(model.entries(.conflict).map(\.endpoint.host) == ["changed.example.com"])
        #expect(model.selection == Set(model.entries(.new).map(\.id)))
    }

    @Test func importPinsOnlyCheckedNewEntriesAndNeverReplaces() async {
        let other = ed25519Blob.dropLast(2) + "xx"
        let store = InMemoryKnownHostsStore(pins: [HostEndpoint(host: "changed.example.com"): [key(String(other))]])
        let model = KnownHostsImportModel()
        model.load(text: """
        a.example.com ssh-ed25519 \(ed25519Blob)
        b.example.com ssh-ed25519 \(ed25519Blob)
        changed.example.com ssh-ed25519 \(ed25519Blob)
        |1|F1E1KeoE/eEWhi10WpGv4OdiO6Y=|3988QV0VbkuUlFskmfOfUZhJKxE= ssh-ed25519 \(ed25519Blob)
        """, sourceName: "known_hosts")
        await model.classify(using: store)
        // The user unchecks b.example.com and force-checks the conflict: the conflict must still be left alone.
        let b = model.entries(.new).first { $0.endpoint.host == "b.example.com" }!
        model.selection.remove(b.id)
        model.selection.formUnion(model.entries(.conflict).map(\.id))

        let summary = await model.importSelected(using: store)

        #expect(summary == KnownHostsImportSummary(imported: 1, alreadyTrusted: 0, conflicts: 1, failed: 0, hashedSkipped: 1))
        #expect(await store.pinned(for: HostEndpoint(host: "a.example.com")).count == 1)
        #expect(await store.pinned(for: HostEndpoint(host: "b.example.com")).isEmpty)
        let pins = await store.pinned(for: HostEndpoint(host: "changed.example.com"))
        #expect(pins.map(\.key.blobBase64) == [String(other)])
    }

    @Test func fullyHashedFileExplainsWhyNothingImports() {
        let model = KnownHostsImportModel()
        model.load(text: "|1|F1E1KeoE/eEWhi10WpGv4OdiO6Y=|3988QV0VbkuUlFskmfOfUZhJKxE= ssh-ed25519 \(ed25519Blob)", sourceName: "known_hosts")
        #expect(model.result.entries.isEmpty)
        #expect(model.errorMessage?.contains("hashed") == true)
    }
}

@Suite struct TildeURLParserTests {
    private let parser = TildeURLParser(quickConnect: FakeQuickConnectParser(defaultUser: "root"))

    @Test func sshLinksGoThroughQuickConnect() throws {
        let action = parser.parse(try #require(URL(string: "ssh://deploy@10.0.4.12:2222")))
        #expect(action == .connect(QuickConnectResult(target: ConnectionTarget(host: "10.0.4.12", port: 2222, username: "deploy"))))
    }

    @Test func tildeConnectWithQueryAndPath() throws {
        let query = parser.parse(try #require(URL(string: "tilde://connect?host=db.example.com&port=2200&user=pg")))
        #expect(query == .connect(QuickConnectResult(target: ConnectionTarget(host: "db.example.com", port: 2200, username: "pg"))))
        let path = parser.parse(try #require(URL(string: "tilde://connect/pg@db.example.com:2200")))
        #expect(path == query)
        let defaults = parser.parse(try #require(URL(string: "tilde://connect?host=db.example.com")))
        #expect(defaults == .connect(QuickConnectResult(target: ConnectionTarget(host: "db.example.com", port: 22, username: "root"))))
    }

    @Test func newServerCarriesTheName() throws {
        let action = parser.parse(try #require(URL(string: "tilde://new-server?host=pi.local&user=pi&name=Pi%20hole")))
        #expect(action == .newServer(QuickConnectResult(target: ConnectionTarget(host: "pi.local", port: 22, username: "pi")), name: "Pi hole"))
    }

    @Test func destinations() throws {
        #expect(parser.parse(try #require(URL(string: "tilde://keys"))) == .show(.keys))
        #expect(parser.parse(try #require(URL(string: "tilde://settings"))) == .show(.settings))
    }

    @Test func rejectsHostileOrUnknownLinks() throws {
        for text in [
            "tilde://connect?host=-oProxyCommand%3Devil",
            "tilde://connect?host=ok.example.com&port=0",
            "tilde://connect?host=ok.example.com&port=70000",
            "tilde://connect?host=ok.example.com&user=-x",
            "tilde://connect?host=bad%20host",
            "tilde://connect",
            "tilde://nope",
            "https://example.com",
        ] {
            #expect(parser.parse(try #require(URL(string: text))) == nil, "\(text) should be rejected")
        }
    }
}
