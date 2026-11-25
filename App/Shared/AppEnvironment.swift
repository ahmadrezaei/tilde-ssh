import Foundation
import Observation
import SwiftData
import TildeCore
import TildeStore

/// Dependency-injection container. Owned by WS5; wired to real implementations in Phase 2.
///
/// Phase 0: every service is a mock from `TildeCore/Mocks`, and the store is in-memory with preview data, so
/// the app runs end-to-end with no network, Keychain or iCloud. To swap in the real thing, replace the
/// corresponding line in `mock()` (or add a `live()` factory) and nothing else in the app changes.
@MainActor
@Observable
final class AppEnvironment {
    /// The Sendable service contracts (secrets, keys, known hosts, engine, probes, parsers, snippets).
    let services: TildeServices
    /// The app lock. `@MainActor`, not Sendable, so it is held outside `TildeServices`.
    let appLock: any AppLocking
    let modelContainer: ModelContainer

    /// Identifiers from `Config/Shared.xcconfig`, surfaced through Info.plist so forks change one file.
    let cloudKitContainerID: String
    let keychainAccessGroup: String?

    init(
        services: TildeServices,
        appLock: any AppLocking,
        modelContainer: ModelContainer,
        cloudKitContainerID: String = AppEnvironment.infoString("TildeCloudKitContainer") ?? ModelContainerFactory.defaultCloudKitContainerID,
        keychainAccessGroup: String? = AppEnvironment.infoString("TildeKeychainAccessGroup")
    ) {
        self.services = services
        self.appLock = appLock
        self.modelContainer = modelContainer
        self.cloudKitContainerID = cloudKitContainerID
        self.keychainAccessGroup = keychainAccessGroup
    }

    /// All mocks, in-memory store seeded with preview data.
    static func mock() -> AppEnvironment {
        AppEnvironment(
            services: .preview,
            appLock: FakeAppLock(),
            modelContainer: ModelContainerFactory.preview()
        )
    }

    nonisolated private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}
