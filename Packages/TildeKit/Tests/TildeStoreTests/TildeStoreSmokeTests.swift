import Foundation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

@Suite struct TildeStoreSmokeTests {
    @Test func moduleLoads() { #expect(TildeStoreModule.name == "TildeStore") }

    @Test func schemaV1ContainsAllEntities() {
        #expect(TildeSchemaV1.models.count == 7)
        #expect(TildeMigrationPlan.schemas.count == 1)
    }

    @MainActor
    @Test func inMemoryContainerRoundTripsRelationships() throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let context = container.mainContext
        let key = SSHKeyRecord(name: "k", privateSecretID: UUID())
        let group = ServerGroup(name: "Prod")
        let tag = Tag(name: "db")
        let bastion = Server(name: "bastion", host: "b.example.com", username: "ops")
        let server = Server(name: "db", host: "10.0.0.5", username: "postgres")
        server.key = key
        server.group = group
        server.tags = [tag]
        server.jumpServer = bastion
        context.insert(key); context.insert(group); context.insert(tag); context.insert(bastion); context.insert(server)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Server>(predicate: #Predicate { $0.name == "db" }))
        #expect(fetched.count == 1)
        #expect(fetched[0].key?.name == "k")
        #expect(key.servers?.count == 1)
        #expect(group.servers?.first?.name == "db")
        #expect(tag.servers?.count == 1)
        #expect(bastion.jumpedBy?.first?.name == "db")
    }

    @MainActor
    @Test func previewSeedPopulates() throws {
        let container = ModelContainerFactory.preview()
        let servers = try container.mainContext.fetch(FetchDescriptor<Server>())
        #expect(servers.count == PreviewServers.all.count)
    }

    @Test func serverDefaultsMatchDesign() {
        let s = Server()
        #expect(s.port == 22 && s.keepAliveSeconds == 30 && s.termType == "xterm-256color" && s.tmuxSessionName == "tilde")
        #expect(s.authMethodRaw == "key" && s.environmentRaw == "none")
    }
}
