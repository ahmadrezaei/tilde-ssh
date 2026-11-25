import Foundation
import SwiftData
import TildeCore

/// CRUD, ordering and search for `Snippet`.
@MainActor
public final class SnippetRepository {
    public let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    /// Snippets in display order: favourites first, then manual order, then name.
    /// `scope`: `nil` = global snippets only, a server = global plus that server's own snippets.
    public func all(scope server: Server? = nil) throws -> [Snippet] {
        let serverID = server?.id
        return try context.fetch(FetchDescriptor<Snippet>())
            .filter { $0.scopeServer == nil || $0.scopeServer?.id == serverID }
            .sorted(by: Snippet.displayOrder)
    }

    public func snippet(id: UUID) throws -> Snippet? {
        var descriptor = FetchDescriptor<Snippet>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Search by name, command and folder; best match first. An empty query returns display order.
    public func search(_ query: String, scope server: Server? = nil) throws -> [Snippet] {
        let matches = SnippetSearch.rank(try all(scope: server), query: query) { ($0.name, $0.command, $0.folder) }
        return matches
    }

    /// Appends a snippet at the end of the list.
    @discardableResult
    public func add(name: String, command: String, folder: String? = nil, runMode: SnippetRunMode = .insert, scope: Server? = nil) throws -> Snippet {
        guard !command.isEmpty else { throw StoreError.invalidValue("A snippet needs a command.") }
        let snippet = Snippet(name: name.nilIfBlank ?? command, command: command, runModeRaw: runMode.rawValue)
        snippet.folder = folder?.nilIfBlank
        snippet.scopeServer = scope
        snippet.sortIndex = FractionalOrder.appended(after: try all().map(\.sortIndex).max())
        context.insert(snippet)
        try context.save()
        return snippet
    }

    /// Saves edits made directly to a snippet.
    public func save(_ snippet: Snippet) throws {
        snippet.updatedAt = .now
        try context.save()
    }

    public func setFavorite(_ snippet: Snippet, _ isFavorite: Bool) throws {
        snippet.isFavorite = isFavorite
        snippet.updatedAt = .now
        try context.save()
    }

    public func delete(_ snippet: Snippet) throws {
        context.delete(snippet)
        try context.save()
    }

    /// Drag-to-reorder within the displayed list (`onMove` semantics). Only moved snippets are rewritten.
    public func reorder(_ snippets: [Snippet], fromOffsets offsets: IndexSet, toOffset destination: Int) throws {
        let changed = FractionalOrder.move(snippets, fromOffsets: offsets, toOffset: destination, index: \.sortIndex, setIndex: { $0.sortIndex = $1 })
        for snippet in changed { snippet.updatedAt = .now }
        try context.save()
    }
}

extension Snippet {
    /// Favourites first, then manual order, then name, then id (stable across devices).
    static func displayOrder(_ lhs: Snippet, _ rhs: Snippet) -> Bool {
        if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return byName != .orderedSame ? byName == .orderedAscending : lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Ranking shared by `SnippetRepository.search` and `SwiftDataSnippetProvider`.
enum SnippetSearch {
    /// Keeps the elements matching every whitespace-separated term in name, command or folder, best first
    /// (name matches outrank command matches). The input order breaks ties, so favourites stay on top.
    static func rank<Element>(_ elements: [Element], query: String, fields: (Element) -> (name: String, command: String, folder: String?)) -> [Element] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return elements }
        let scored: [(offset: Int, element: Element, score: Int)] = elements.enumerated().compactMap { offset, element in
            let (name, command, folder) = fields(element)
            var total = 0
            for term in terms {
                let nameScore = FuzzyMatcher.score(term: term, in: name).map { $0 * 2 }
                let commandScore = FuzzyMatcher.score(term: term, in: command)
                let folderScore = folder.flatMap { FuzzyMatcher.score(term: term, in: $0) }
                guard let best = [nameScore, commandScore, folderScore].compactMap({ $0 }).max() else { return nil }
                total += best
            }
            return (offset, element, total)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }.map(\.element)
    }
}
