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

    /// `true` for `.cloudKit`.
    public var isSyncing: Bool {
        if case .cloudKit = self { return true }
        return false
    }
}

/// A container together with the mode it actually runs in (which can differ from the requested one).
public struct StoreBootstrap: Sendable {
    public let container: ModelContainer
    /// The mode in use. `.local` when CloudKit was wanted but not available.
    public let mode: StoreMode
    /// Why CloudKit was not used, when it was wanted. Not shown to users verbatim; for logs and Settings detail.
    public let cloudKitUnavailableReason: String?
}

public enum ModelContainerFactory {
    /// Matches the entitlement in `Config/Shared.xcconfig`; forks override it there.
    public static let defaultCloudKitContainerID = "iCloud.app.tildessh.Tilde"

    /// The on-disk store name. Cloud and local modes deliberately share it, so turning sync on later
    /// mirrors the existing store in place instead of starting empty.
    public static let storeName = "Tilde"

    /// Builds a container for exactly `mode`. `.cloudKit` throws or traps when the process lacks the iCloud
    /// entitlement; use `makeBestAvailable` to fall back gracefully.
    ///
    /// - Parameter storeURL: overrides the on-disk location (tests); `nil` uses the default Application Support location.
    public static func make(_ mode: StoreMode, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = Schema.tilde
        let configuration: ModelConfiguration
        switch mode {
        case .cloudKit(let containerID):
            configuration = storeURL.map { ModelConfiguration(storeName, schema: schema, url: $0, cloudKitDatabase: .private(containerID)) }
                ?? ModelConfiguration(storeName, schema: schema, cloudKitDatabase: .private(containerID))
        case .local:
            configuration = storeURL.map { ModelConfiguration(storeName, schema: schema, url: $0, cloudKitDatabase: .none) }
                ?? ModelConfiguration(storeName, schema: schema, cloudKitDatabase: .none)
        case .inMemory:
            configuration = ModelConfiguration(storeName, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: TildeMigrationPlan.self, configurations: [configuration])
    }

    /// The production entry point: CloudKit when it is wanted and possible, otherwise the local store.
    ///
    /// CloudKit is skipped (no error) when `syncEnabled` is false, the process is not entitled to the container,
    /// the user is signed out of iCloud, or `TILDE_DISABLE_CLOUDKIT=1`. If creating the CloudKit store throws,
    /// the local store is used and the reason is reported. The local store throws only when the on-disk
    /// store itself is unusable, which the app should surface.
    ///
    /// - Parameters:
    ///   - syncEnabled: the user's "Sync on/off" switch (a per-device preference).
    ///   - containerID: the CloudKit container identifier.
    ///   - storeURL: overrides the on-disk location (tests).
    ///   - cloudKitCheck: availability check, injectable for tests.
    public static func makeBestAvailable(
        syncEnabled: Bool = true,
        containerID: String = defaultCloudKitContainerID,
        storeURL: URL? = nil,
        cloudKitCheck: (String) -> Bool = CloudKitAvailability.canUseCloudKit(containerID:)
    ) throws -> StoreBootstrap {
        var reason: String?
        if !syncEnabled {
            reason = "Sync is turned off."
        } else if !cloudKitCheck(containerID) {
            reason = "iCloud is not available to this build or no account is signed in."
        } else {
            do {
                let container = try make(.cloudKit(containerID: containerID), storeURL: storeURL)
                return StoreBootstrap(container: container, mode: .cloudKit(containerID: containerID), cloudKitUnavailableReason: nil)
            } catch {
                reason = "The iCloud store could not be opened: \(error.localizedDescription)"
            }
        }
        return StoreBootstrap(container: try make(.local, storeURL: storeURL), mode: .local, cloudKitUnavailableReason: reason)
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

    /// A fresh, empty in-memory container (unit tests).
    public static func inMemory() throws -> ModelContainer { try make(.inMemory) }
}
