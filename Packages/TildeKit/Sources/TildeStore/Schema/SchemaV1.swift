import Foundation
import SwiftData

/// Schema version 1. Schema changes after the first production CloudKit deploy must be **additive only**
/// (new optional or defaulted fields, or new entities). Add a `TildeSchemaV2` and a migration stage
/// when that happens; until then, the `@Model` classes in this folder are the v1 definition.
///
/// CloudKit rules (docs/DESIGN.md section 6.1): every attribute optional or defaulted, no
/// `@Attribute(.unique)`, relationships optional with inverses, no ordered relationships, no `.deny` delete rule.
public enum TildeSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            Server.self,
            ServerGroup.self,
            Tag.self,
            SSHKeyRecord.self,
            KnownHost.self,
            Snippet.self,
            RecentConnection.self,
        ]
    }
}

/// The migration plan. Empty until there is a schema v2.
public enum TildeMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [TildeSchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

public extension Schema {
    /// The current schema (always the latest `TildeSchemaV*`).
    static var tilde: Schema { Schema(versionedSchema: TildeSchemaV1.self) }
}
