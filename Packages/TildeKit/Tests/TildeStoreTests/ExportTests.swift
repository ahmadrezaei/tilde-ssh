import Foundation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

@MainActor
@Suite struct ExportTests {
    private func populatedContainer() throws -> (ModelContainer, StoreRepositories) {
        let container = try makeContainer()
        let repositories = StoreRepositories(container: container)
        let key = try repositories.keys.add(SSHKeyRecord(name: "macbook", algorithmRaw: "ssh-ed25519", publicKeyOpenSSH: "ssh-ed25519 AAAA tilde@mac", fingerprintSHA256: "SHA256:fp1", privateSecretID: UUID()))
        let group = try repositories.groups.add(name: "Production", symbol: "bolt.fill")

        let bastion = Server(name: "bastion", host: "Bastion.Example.com", username: "ops")
        bastion.key = key
        try repositories.servers.add(bastion)

        let api = Server(name: "prod-api", host: "10.0.1.12", port: 2222, username: "deploy", environmentRaw: "prod")
        api.key = key
        api.group = group
        api.jumpServer = bastion
        api.isFavorite = true
        api.startupCommand = "tmux new -A -s api"
        api.autoTmux = true
        api.envVars = ["LANG": "en_US.UTF-8"]
        api.notes = "Primary API, handle with care"
        try repositories.servers.add(api)
        try repositories.tags.setTags(["k8s", "edge"], on: api)

        let withPassword = Server(name: "staging", host: "staging.example.com", username: "deploy", authMethodRaw: "password", environmentRaw: "staging")
        withPassword.passwordSecretID = UUID()
        try repositories.servers.add(withPassword)
        return (container, repositories)
    }

    @Test func exportContainsNoSecretsOrKeychainIdentifiers() throws {
        let (container, repositories) = try populatedContainer()
        let data = try ServerExporter.exportAll(from: container.mainContext)
        let text = String(decoding: data, as: UTF8.self)
        let secretID = try #require(try repositories.servers.all().first { $0.passwordSecretID != nil }?.passwordSecretID)
        let keyRecord = try #require(try repositories.keys.all().first)

        #expect(!text.contains(secretID.uuidString), "the password's Keychain id is not exported")
        #expect(!text.contains(keyRecord.privateSecretID.uuidString), "the private key's Keychain id is not exported")
        #expect(!text.lowercased().contains("passwordsecret"))
        #expect(!text.contains("PRIVATE KEY"))
        #expect(text.contains("SHA256:fp1"), "keys are referenced by their public fingerprint")
        #expect(text.contains("\"auth\" : \"passwordPrompt\""), "a saved-password server is exported as ask-every-time")
        #expect(!text.contains("\"auth\" : \"password\""))
    }

    @Test func roundTripRebuildsTheServerList() throws {
        let (source, sourceRepos) = try populatedContainer()
        let data = try ServerExporter.exportAll(from: source.mainContext)

        // A second device that already has the same key (synced), but no servers.
        let target = try makeContainer()
        let targetRepos = StoreRepositories(container: target)
        try targetRepos.keys.add(SSHKeyRecord(name: "macbook", algorithmRaw: "ssh-ed25519", publicKeyOpenSSH: "ssh-ed25519 AAAA tilde@mac", fingerprintSHA256: "SHA256:fp1", privateSecretID: UUID()))

        let report = try ServerExporter.import(data, into: target.mainContext)
        #expect(report.imported == 3 && report.skippedExisting == 0 && report.skippedInvalid == 0)
        #expect(report.passwordsNotImported == 0, "the exporter already turned saved passwords into ask-every-time")
        #expect(report.unresolvedKeys == 0)

        let api = try #require(try targetRepos.servers.all().first { $0.name == "prod-api" })
        let original = try #require(try sourceRepos.servers.all().first { $0.name == "prod-api" })
        #expect(api.id == original.id)
        #expect(api.connectionTarget == original.connectionTarget)
        #expect(api.environment == .prod && api.isFavorite && api.autoTmux)
        #expect(api.startupCommand == nil, "a startup command runs on every connection, so it is not imported")
        #expect(api.autoTmux && api.notes == "Primary API, handle with care")
        #expect(report.startupCommandsNotImported == 1)
        #expect(api.envVars == ["LANG": "en_US.UTF-8"])
        #expect(api.group?.name == "Production" && api.group?.symbol == "bolt.fill")
        #expect(api.tagList.map(\.name).sorted() == ["edge", "k8s"])
        #expect(api.key?.fingerprintSHA256 == "SHA256:fp1")
        #expect(api.jumpServer == nil, "a jump host that arrives in the same file is not trusted as a route")
        #expect(report.jumpHostsNotImported == 1 && report.jumpHostsLinked == 0)
        #expect(api.sortIndex == original.sortIndex)

        let staging = try #require(try targetRepos.servers.all().first { $0.name == "staging" })
        #expect(staging.authMethod == .passwordPrompt && staging.passwordSecretID == nil)

        // Snapshots of both sides agree, apart from the secret reference that is deliberately dropped.
        var expected = ServerSnapshot(model: original)
        expected.keyID = api.key?.privateSecretID
        expected.jump = nil
        expected.startupCommand = nil
        #expect(ServerSnapshot(model: api) == expected)
    }

    @Test func aJumpHostThatAlreadyExistsIsLinked() throws {
        let (source, _) = try populatedContainer()
        let data = try ServerExporter.exportAll(from: source.mainContext)

        // This device already has the bastion (same id) but not the server behind it.
        var document = try ServerExporter.decode(data)
        let bastionEntry = try #require(document.servers.first { $0.name == "bastion" })
        document.servers.removeAll { $0.name == "bastion" }
        let target = try makeContainer()
        let targetRepos = StoreRepositories(container: target)
        let bastion = Server(name: "bastion", host: "bastion.example.com", username: "ops")
        bastion.id = bastionEntry.id
        try targetRepos.servers.add(bastion)

        let report = try ServerExporter.import(JSONEncoder.iso.encode(document), into: target.mainContext)
        let api = try #require(try targetRepos.servers.all().first { $0.name == "prod-api" })
        #expect(api.jumpServer?.id == bastion.id)
        #expect(report.jumpHostsLinked == 1 && report.jumpHostsNotImported == 0)
    }

    @Test func exportIsDeterministic() throws {
        let (container, _) = try populatedContainer()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try ServerExporter.exportAll(from: container.mainContext, now: now) == ServerExporter.exportAll(from: container.mainContext, now: now))
    }

    @Test func importingTwiceIsANoOp() throws {
        let (container, _) = try populatedContainer()
        let data = try ServerExporter.exportAll(from: container.mainContext)
        let report = try ServerExporter.import(data, into: container.mainContext)
        #expect(report.imported == 0 && report.skippedExisting == 3)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Server>()) == 3)

        // Same server under a new id (exported from another account) is skipped by name, host, port and user.
        var document = try ServerExporter.decode(data)
        document.servers[0].id = UUID()
        let renumbered = try JSONEncoder.iso.encode(document)
        #expect(try ServerExporter.import(renumbered, into: container.mainContext).imported == 0)
    }

    @Test func missingKeyIsReportedAndKeepsTheServer() throws {
        let (source, _) = try populatedContainer()
        let data = try ServerExporter.exportAll(from: source.mainContext)
        let target = try makeContainer()
        let report = try ServerExporter.import(data, into: target.mainContext)
        #expect(report.imported == 3 && report.unresolvedKeys == 2)
        #expect(try ServerRepository(context: target.mainContext).all().first { $0.name == "prod-api" }?.key == nil)
    }

    @Test func invalidEntriesAreSkippedNotFatal() throws {
        var document = ServerExportDocument(format: "tilde-servers", version: 1, exportedAt: .now, groups: [], servers: [])
        func entry(host: String, port: Int) -> ServerExportDocument.Entry {
            .init(id: UUID(), name: "n", host: host, port: port, username: "u", auth: "key", keyFingerprint: nil, keyName: nil, environment: "weird",
                  group: nil, tags: [], jumpServerID: nil, isFavorite: false, sortIndex: 1, startupCommand: nil, autoTmux: false,
                  tmuxSessionName: "tilde", keepAliveSeconds: 30, termType: "xterm-256color", envVars: [:], notes: nil)
        }
        document.servers = [entry(host: "", port: 22), entry(host: "ok", port: 0), entry(host: "good", port: 22)]
        let container = try makeContainer()
        let report = try ServerExporter.import(JSONEncoder.iso.encode(document), into: container.mainContext)
        #expect(report.imported == 1 && report.skippedInvalid == 2)
        #expect(try ServerRepository(context: container.mainContext).all().first?.environment == ServerEnvironment.none)
    }

    @Test func rejectsFilesThatAreNotServerExports() throws {
        #expect(throws: ServerImportError.notAServerExport) { try ServerExporter.decode(Data("{\"hello\":1}".utf8)) }
        #expect(throws: ServerImportError.notAServerExport) { try ServerExporter.decode(Data("not json at all".utf8)) }
        #expect(throws: ServerImportError.notAServerExport) { try ServerExporter.decode(Data("[]".utf8)) }
        let future = ServerExportDocument(format: "tilde-servers", version: 99, exportedAt: .now, groups: [], servers: [])
        #expect(throws: ServerImportError.unsupportedVersion(99)) { try ServerExporter.decode(JSONEncoder.iso.encode(future)) }
        let wrongFormat = ServerExportDocument(format: "something-else", version: 1, exportedAt: .now, groups: [], servers: [])
        #expect(throws: ServerImportError.notAServerExport) { try ServerExporter.decode(JSONEncoder.iso.encode(wrongFormat)) }
        let damaged = Data("{\"format\":\"tilde-servers\",\"version\":1,\"servers\":\"oops\"}".utf8)
        #expect(throws: ServerImportError.self) { try ServerExporter.decode(damaged) }
    }

    @Test func aHandEditedPasswordEntryBecomesAskEveryTime() throws {
        let container = try makeContainer()
        var document = ServerExportDocument(format: "tilde-servers", version: 1, exportedAt: .now, groups: [], servers: [])
        document.servers = [.init(
            id: UUID(), name: "n", host: "h", port: 22, username: "u", auth: "password", keyFingerprint: nil, keyName: nil, environment: "none",
            group: nil, tags: [], jumpServerID: nil, isFavorite: false, sortIndex: 1, startupCommand: nil, autoTmux: false,
            tmuxSessionName: "tilde", keepAliveSeconds: 30, termType: "xterm-256color", envVars: [:], notes: nil
        )]
        let report = try ServerExporter.import(JSONEncoder.iso.encode(document), into: container.mainContext)
        #expect(report.passwordsNotImported == 1)
        #expect(try ServerRepository(context: container.mainContext).all().first?.authMethod == .passwordPrompt)
    }

    @Test func exportOfAnEmptyStoreIsValid() throws {
        let container = try makeContainer()
        let data = try ServerExporter.exportAll(from: container.mainContext)
        #expect(try ServerExporter.decode(data).servers.isEmpty)
        #expect(try ServerExporter.import(data, into: container.mainContext).imported == 0)
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
