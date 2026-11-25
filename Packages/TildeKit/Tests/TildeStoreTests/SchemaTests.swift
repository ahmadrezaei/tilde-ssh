import Foundation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

/// Guards the CloudKit rules from docs/DESIGN.md section 6.1 so a future schema edit cannot break sync silently.
@Suite struct SchemaTests {
    @Test func schemaHasTheSevenEntities() {
        let names = Set(Schema.tilde.entities.map(\.name))
        #expect(names == ["Server", "ServerGroup", "Tag", "SSHKeyRecord", "KnownHost", "Snippet", "RecentConnection"])
        #expect(TildeSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(TildeMigrationPlan.schemas.count == 1 && TildeMigrationPlan.stages.isEmpty)
    }

    @Test func noUniqueConstraints() {
        for entity in Schema.tilde.entities {
            #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name) has a uniqueness constraint")
            for attribute in entity.attributes {
                #expect(!attribute.options.contains(.unique), "\(entity.name).\(attribute.name) is unique")
            }
        }
    }

    @Test func relationshipsAreOptionalWithInversesAndNeverDeny() {
        for entity in Schema.tilde.entities {
            for relationship in entity.relationships {
                let label = "\(entity.name).\(relationship.name)"
                #expect(relationship.isOptional, "\(label) must be optional")
                #expect(relationship.inverseName != nil, "\(label) needs an inverse")
                #expect(relationship.deleteRule != .deny, "\(label) must not use .deny")
                #expect(!relationship.options.contains(.unique), "\(label)")
            }
        }
    }

    @Test func everyEntityCarriesIdAndTimestamps() {
        for entity in Schema.tilde.entities {
            let names = Set(entity.attributes.map(\.name))
            #expect(names.isSuperset(of: ["id", "createdAt", "updatedAt"]), "\(entity.name) is missing a standard column")
        }
    }

    @Test func everyAttributeIsOptionalOrDefaulted() {
        // A fresh default-constructed record of every entity must be insertable and savable: this is what
        // CloudKit requires when a record arrives with missing fields.
        let container = try! makeContainer()
        let context = ModelContext(container)
        context.insert(Server()); context.insert(ServerGroup()); context.insert(Tag()); context.insert(SSHKeyRecord())
        context.insert(KnownHost()); context.insert(Snippet()); context.insert(RecentConnection())
        #expect(throws: Never.self) { try context.save() }
    }

    @Test func noPrivateMaterialColumnsExist() {
        // Secrets are referenced by UUID only (docs/DESIGN.md section 6.2).
        let forbidden = ["password", "passphrase", "privatekey", "secret"]
        for entity in Schema.tilde.entities {
            for attribute in entity.attributes {
                let name = attribute.name.lowercased()
                for word in forbidden where name.contains(word) {
                    #expect(name.hasSuffix("id"), "\(entity.name).\(attribute.name) looks like it could hold a secret")
                }
            }
        }
    }
}
