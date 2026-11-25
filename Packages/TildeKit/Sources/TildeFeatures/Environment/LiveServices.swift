import Foundation
import SwiftData
import TildeCore
import TildeSSH
import TildeSecurity
import TildeStore

/// The real service stack: Keychain secrets, SwiftData host keys and snippets, the SSH engine, and the
/// parsers. `AppEnvironment` builds it once at launch; integration tests build it with an in-memory container and
/// secret store, so they exercise the same wiring as the app.
public enum LiveServices {
    /// - Parameters:
    ///   - container: the store's container (keep it alive for the app's lifetime).
    ///   - secretStore: where passwords and private keys live; the Keychain in the app.
    ///   - engineDefaults: the per-device defaults the engine reads at the start of each session.
    @MainActor
    public static func make(
        container: ModelContainer,
        secretStore: any SecretStore = KeychainSecretStore(),
        engineDefaults: UserDefaults = .standard
    ) -> TildeServices {
        TildeServices(
            secretStore: secretStore,
            keyService: DefaultKeyService(),
            knownHosts: SwiftDataKnownHostsStore(modelContainer: container),
            credentials: DefaultCredentialResolver(secretStore: secretStore),
            sessionEngine: SettingsSessionEngine(defaults: engineDefaults),
            reachability: NWReachabilityProbe(),
            quickConnect: SettingsQuickConnectParser(),
            sshConfig: SSHConfigParser(),
            snippets: SwiftDataSnippetProvider(container: container)
        )
    }
}

/// `CitadelSessionEngine` configured from Settings. The engine's options are fixed when it is created, so this builds
/// one per call from the stored preferences: a changed "Strict host checking" or "Allow legacy ssh-rsa" applies to the
/// next session without restarting the app (open sessions keep what they started with).
public struct SettingsSessionEngine: SessionEngine {
    // `UserDefaults` is thread-safe but not declared `Sendable`.
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The options for a session started now.
    public var currentOptions: CitadelSessionEngine.Options {
        CitadelSessionEngine.Options(
            strictHostKeyChecking: SecuritySettings.storedStrictHostChecking(in: defaults),
            hostKeyPromptTimeout: .seconds(120),
            reconnect: .default,
            keepAliveMissLimit: 3,
            allowLegacySSHRSA: SecuritySettings.storedAllowLegacySSHRSA(in: defaults)
        )
    }

    private var engine: CitadelSessionEngine { CitadelSessionEngine(options: currentOptions) }

    public func makeSession(
        _ request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore,
        hostKeyPrompter: any HostKeyPrompter,
        passwordPrompter: any PasswordPrompter
    ) -> any TerminalSession {
        engine.makeSession(request, credentials: credentials, knownHosts: knownHosts, hostKeyPrompter: hostKeyPrompter, passwordPrompter: passwordPrompter)
    }

    public func test(
        _ request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore,
        hostKeyPrompter: any HostKeyPrompter,
        passwordPrompter: any PasswordPrompter
    ) async -> Result<ConnectionInfo, SessionError> {
        await engine.test(request, credentials: credentials, knownHosts: knownHosts, hostKeyPrompter: hostKeyPrompter, passwordPrompter: passwordPrompter)
    }

    public func runCommand(
        _ command: String,
        on request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore
    ) async throws -> (stdout: Data, exitStatus: Int) {
        try await engine.runCommand(command, on: request, credentials: credentials, knownHosts: knownHosts)
    }
}

/// `QuickConnectParser` with the default username from Settings (`root` when unset), read at parse time.
public struct SettingsQuickConnectParser: QuickConnectParsing {
    public init() {}

    public func parse(_ input: String) -> QuickConnectResult? {
        QuickConnectParser(defaultUsername: TildeSettings.currentDefaultUser).parse(input)
    }
}
