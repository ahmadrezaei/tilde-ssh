import Foundation
import Observation
import SwiftData
import TildeCore
import TildeFeatures
import TildeSecurity
import TildeStore

/// Dependency-injection container for the app.
///
/// `live()` wires the real implementations (SwiftData + CloudKit store, Keychain, SSH engine, App Lock).
/// `mock()` keeps the in-memory mocks from `TildeCore/Mocks` for SwiftUI previews and for running without a network,
/// Keychain or iCloud (launch with `TILDE_MOCK_ENVIRONMENT=1`).
@MainActor
@Observable
final class AppEnvironment {
    /// The Sendable service contracts (secrets, keys, known hosts, engine, probes, parsers, snippets).
    let services: TildeServices
    /// The app lock. `@MainActor`, not Sendable, so it is held outside `TildeServices`.
    let appLock: any AppLocking
    let modelContainer: ModelContainer
    /// Owns every open session and answers host-key and password prompts. Built from `services`.
    let coordinator: SessionCoordinator

    /// Settings > Sync. `nil` with the mocks.
    let preferences: Preferences?
    let syncMonitor: SyncStatusMonitor?
    /// Kept alive for the app's lifetime: it merges duplicate tags and groups that CloudKit sync can create.
    @ObservationIgnored private let deduplication: DeduplicationCoordinator?

    /// Identifiers from `Config/Shared.xcconfig`, surfaced through Info.plist so forks change one file.
    let cloudKitContainerID: String
    let keychainAccessGroup: String?

    init(
        services: TildeServices,
        appLock: any AppLocking,
        modelContainer: ModelContainer,
        preferences: Preferences? = nil,
        syncMonitor: SyncStatusMonitor? = nil,
        deduplication: DeduplicationCoordinator? = nil,
        cloudKitContainerID: String = AppEnvironment.infoString("TildeCloudKitContainer") ?? ModelContainerFactory.defaultCloudKitContainerID,
        keychainAccessGroup: String? = AppEnvironment.infoString("TildeKeychainAccessGroup")
    ) {
        self.services = services
        self.appLock = appLock
        self.modelContainer = modelContainer
        self.preferences = preferences
        self.syncMonitor = syncMonitor
        self.deduplication = deduplication
        self.cloudKitContainerID = cloudKitContainerID
        self.keychainAccessGroup = keychainAccessGroup
        self.coordinator = SessionCoordinator(services: services)
        coordinator.recordConnections(in: modelContainer.mainContext)
    }

    // MARK: Live

    /// The real app. Throws only when the on-disk store itself cannot be opened (the app shows that, rather than
    /// silently running on an empty in-memory store and losing what the user adds).
    static func live() throws -> AppEnvironment {
        let preferences = Preferences.live()
        let containerID = infoString("TildeCloudKitContainer") ?? ModelContainerFactory.defaultCloudKitContainerID
        // `makeBestAvailable` falls back to the local store when the build has no iCloud entitlement
        // (the `TildeCloudKitEnabled` Info.plist key on iOS) or the user turned sync off.
        let boot = try ModelContainerFactory.makeBestAvailable(syncEnabled: preferences.syncEnabled, containerID: containerID)

        let services = LiveServices.make(container: boot.container, secretStore: KeychainSecretStore())

        let syncMonitor = SyncStatusMonitor(mode: boot.mode, syncEnabled: preferences.syncEnabled, containerID: containerID)
        syncMonitor.start()
        let deduplication = DeduplicationCoordinator(container: boot.container)
        deduplication.start()
        _ = try? SnippetSeeds.seedIfNeeded(in: boot.container.mainContext)

        return AppEnvironment(
            services: services,
            appLock: AppLock(),
            modelContainer: boot.container,
            preferences: preferences,
            syncMonitor: syncMonitor,
            deduplication: deduplication,
            cloudKitContainerID: containerID
        )
    }

    /// `live()` unless `TILDE_MOCK_ENVIRONMENT=1` asks for the mocks (demos, UI tests).
    static func launch() -> Result<AppEnvironment, Error> {
        if ProcessInfo.processInfo.environment["TILDE_MOCK_ENVIRONMENT"] == "1" { return .success(mock()) }
        return Result { try live() }
    }

    // MARK: Mock

    /// All mocks, in-memory store seeded with preview data (servers, groups, tags, a key and 8 snippets).
    static func mock() -> AppEnvironment {
        AppEnvironment(
            services: .preview,
            appLock: FakeAppLock(),
            modelContainer: TildePreview.container()
        )
    }

    nonisolated private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}
