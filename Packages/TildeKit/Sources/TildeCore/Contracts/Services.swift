import Foundation

/// A bundle of the Sendable service contracts, so views and coordinators receive one value instead of
/// nine parameters. Built once by `AppEnvironment` and injected into the SwiftUI environment
/// (`EnvironmentValues.tildeServices` in TildeFeatures). Not part of the §10.2 list; see CONTRACTS-NOTES.md.
public struct TildeServices: Sendable {
    public var secretStore: any SecretStore
    public var keyService: any KeyService
    public var knownHosts: any KnownHostsStore
    public var credentials: any CredentialResolver
    public var sessionEngine: any SessionEngine
    public var reachability: any ReachabilityProbe
    public var quickConnect: any QuickConnectParsing
    public var sshConfig: any SSHConfigParsing
    public var snippets: any SnippetProviding

    public init(
        secretStore: any SecretStore,
        keyService: any KeyService,
        knownHosts: any KnownHostsStore,
        credentials: any CredentialResolver,
        sessionEngine: any SessionEngine,
        reachability: any ReachabilityProbe,
        quickConnect: any QuickConnectParsing,
        sshConfig: any SSHConfigParsing,
        snippets: any SnippetProviding
    ) {
        self.secretStore = secretStore
        self.keyService = keyService
        self.knownHosts = knownHosts
        self.credentials = credentials
        self.sessionEngine = sessionEngine
        self.reachability = reachability
        self.quickConnect = quickConnect
        self.sshConfig = sshConfig
        self.snippets = snippets
    }
}
