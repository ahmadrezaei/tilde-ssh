import Foundation
import SwiftData
import TildeCore

/// `SnippetProviding` over the SwiftData store. Sendable (it holds only the container) and callable from any
/// actor: every call reads through its own short-lived `ModelContext`, so it always sees the latest
/// (including synced) snippets and never touches the main context.
public struct SwiftDataSnippetProvider: SnippetProviding {
    private let container: ModelContainer

    public init(container: ModelContainer) { self.container = container }

    /// Global snippets matching `query` (name, command or folder), best match first; an empty query returns
    /// all of them in display order (favourites first, then manual order).
    public func snippets(matching query: String) async -> [SnippetSnapshot] {
        await snippets(matching: query, forServer: nil)
    }

    /// Global snippets plus the ones scoped to `serverID`, for the palette opened inside that session.
    public func snippets(matching query: String, forServer serverID: UUID?) async -> [SnippetSnapshot] {
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<Snippet>())) ?? []
        let visible = all
            .filter { $0.scopeServer == nil || ($0.scopeServer?.id == serverID && serverID != nil) }
            .sorted(by: Snippet.displayOrder)
        return SnippetSearch.rank(visible, query: query) { ($0.name, $0.command, $0.folder) }
            .map { SnippetSnapshot(model: $0) }
    }
}
