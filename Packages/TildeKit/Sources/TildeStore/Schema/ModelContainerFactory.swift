import Foundation
import SwiftData

/// Where the store lives.
public enum StoreMode: Sendable, Equatable {
    /// On-disk, mirrored to the user's private CloudKit database.
    case cloudKit(containerID: String)
    /// On-disk, never synced (iCloud signed out, or the user turned sync off).
    case local
    /// Memory only: previews and tests.
    case inMemory
}

public enum ModelContainerFactory {
    /// Matches the entitlement in `Config/Shared.xcconfig`; forks override it there.
    public static let defaultCloudKitContainerID = "iCloud.app.tildessh.Tilde"

    /// The on-disk store name. Cloud and local modes deliberately share it, so turning sync on later
    /// mirrors the existing store in place instead of starting empty.
    public static let storeName = "Tilde"

    public static func make(_ mode: StoreMode) throws -> ModelContainer {
        let schema = Schema.tilde
        let configuration: ModelConfiguration
        switch mode {
        case .cloudKit(let containerID):
            configuration = ModelConfiguration(storeName, schema: schema, cloudKitDatabase: .private(containerID))
        case .local:
            configuration = ModelConfiguration(storeName, schema: schema, cloudKitDatabase: .none)
        case .inMemory:
            configuration = ModelConfiguration(storeName, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: TildeMigrationPlan.self, configurations: [configuration])
    }

    /// A fresh in-memory container, populated with `PreviewSeed` data. For SwiftUI previews and tests.
    @MainActor
    public static func preview() -> ModelContainer {
        do {
            let container = try make(.inMemory)
            PreviewSeed.populate(container.mainContext)
            return container
        } catch {
            fatalError("Could not create the preview container: \(error)")
        }
    }
}
