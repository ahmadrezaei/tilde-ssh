import Foundation
import SwiftData
import TildeCore

/// All main-actor repositories over one context, so the app builds them once.
///
/// ```swift
/// let repositories = StoreRepositories(container: modelContainer)
/// let servers = try repositories.servers.search("#k8s env:prod")
/// ```
@MainActor
public struct StoreRepositories {
    public let servers: ServerRepository
    public let groups: GroupRepository
    public let tags: TagRepository
    public let keys: KeyRecordRepository
    public let snippets: SnippetRepository
    public let recents: RecentRepository
    public let knownHosts: KnownHostRepository

    /// Keeps the container alive: a `ModelContext` does not retain its container.
    private let container: ModelContainer?

    public init(context: ModelContext, container: ModelContainer? = nil) {
        self.container = container
        servers = ServerRepository(context: context)
        groups = GroupRepository(context: context)
        tags = TagRepository(context: context)
        keys = KeyRecordRepository(context: context)
        snippets = SnippetRepository(context: context)
        recents = RecentRepository(context: context)
        knownHosts = KnownHostRepository(context: context)
    }

    /// Repositories over the container's main context.
    public init(container: ModelContainer) { self.init(context: container.mainContext, container: container) }
}
