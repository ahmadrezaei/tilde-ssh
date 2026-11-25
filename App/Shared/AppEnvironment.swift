import Foundation
import Observation
import SwiftData
import TildeCore
import TildeFeatures
import TildeStore

/// Dependency-injection container. Owned by WS5; wired to real implementations in Phase 2.
///
/// Today every service is a mock from `TildeCore/Mocks`, and the store is in-memory with preview data, so the app runs
/// end-to-end with no network, Keychain or iCloud. Each service is one line in `mock()`; to plug in a real
/// implementation, replace that line (the comment on it names the owner), and nothing else in the app changes.
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
        self.coordinator = SessionCoordinator(services: services)
        coordinator.recordConnections(in: modelContainer.mainContext)
    }

    /// All mocks, in-memory store seeded with preview data (servers, groups, tags, a key and 8 snippets).
    static func mock() -> AppEnvironment {
        AppEnvironment(
            services: TildeServices(
                secretStore: InMemorySecretStore(),            // WS3: Keychain-backed SecretStore
                keyService: FakeKeyService(),                  // WS3: CryptoKit / SecKey KeyService
                knownHosts: InMemoryKnownHostsStore(),         // WS1: SwiftData-backed KnownHostsStore
                credentials: FakeCredentialResolver(),         // WS3: DefaultCredentialResolver
                sessionEngine: FakeSessionEngine(),            // WS2: CitadelSessionEngine
                reachability: FakeReachabilityProbe(),         // WS2: NWConnection ReachabilityProbe
                quickConnect: FakeQuickConnectParser(),        // WS2: QuickConnectParser
                sshConfig: FakeSSHConfigParser(),              // WS2: SSHConfigParser
                snippets: StaticSnippetProvider()              // WS1: SwiftData-backed SnippetProviding
            ),
            appLock: FakeAppLock(),                            // WS3: LocalAuthentication AppLock
            modelContainer: TildePreview.container()           // WS1: ModelContainerFactory.make(.cloudKit / .local)
        )
    }

    nonisolated private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}
