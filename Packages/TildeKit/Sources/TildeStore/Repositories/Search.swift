import Foundation
import TildeCore

/// Small fuzzy matcher shared by the server list, the snippet palette and the command palette.
public enum FuzzyMatcher {
    /// A relevance score for `term` in `text` (higher is better), or `nil` when it does not match.
    ///
    /// Exact match 100, prefix 80, substring 60 (+10 at a word boundary), in-order subsequence 20.
    /// Case-insensitive; an empty term matches everything with score 0.
    public static func score(term: String, in text: String) -> Int? {
        let needle = term.lowercased()
        guard !needle.isEmpty else { return 0 }
        let haystack = text.lowercased()
        if haystack == needle { return 100 }
        if haystack.hasPrefix(needle) { return 80 }
        if let range = haystack.range(of: needle) {
            let boundary = range.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: range.lowerBound)].isLetterOrNumber
            return boundary ? 70 : 60
        }
        guard needle.count >= 2 else { return nil }
        var remaining = needle[...]
        for character in haystack where character == remaining.first {
            remaining.removeFirst()
            if remaining.isEmpty { return 20 }
        }
        return nil
    }

    /// The best score of `term` across `fields`.
    public static func bestScore(term: String, in fields: [String]) -> Int? {
        fields.compactMap { score(term: term, in: $0) }.max()
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}

/// A parsed server-list search string: free text plus `#tag` and `env:prod` filters
/// (docs/DESIGN.md section 4.1).
public struct ServerSearchQuery: Equatable, Sendable {
    /// Free-text terms; every term must match (AND).
    public var terms: [String] = []
    /// `#tag` filters (prefix match on the tag name; every tag must match).
    public var tags: [String] = []
    /// `env:prod`.
    public var environment: ServerEnvironment?

    public init(terms: [String] = [], tags: [String] = [], environment: ServerEnvironment? = nil) {
        self.terms = terms
        self.tags = tags
        self.environment = environment
    }

    /// Parses `"api #k8s env:prod"`. An unknown `env:` value is treated as free text.
    public init(parsing input: String) {
        for token in input.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.hasPrefix("#"), token.count > 1 {
                tags.append(String(token.dropFirst()).lowercased())
            } else if token.lowercased().hasPrefix("env:"),
                      let environment = ServerEnvironment(rawValue: String(token.dropFirst(4)).lowercased()) {
                self.environment = environment
            } else {
                terms.append(token)
            }
        }
    }

    /// `true` when nothing would be filtered.
    public var isEmpty: Bool { terms.isEmpty && tags.isEmpty && environment == nil }

    /// The relevance of `server` for this query, or `nil` if it is filtered out. Pure filters score 0.
    func score(_ server: Server) -> Int? {
        if let environment, server.environment != environment { return nil }
        let tagNames = server.tagList.map { $0.name.lowercased() }
        for wanted in tags where !tagNames.contains(where: { $0.hasPrefix(wanted) }) { return nil }
        let fields = [server.name, server.host, server.username] + server.tagList.map(\.name) + [server.group?.name ?? ""]
        var total = 0
        for term in terms {
            guard let best = FuzzyMatcher.bestScore(term: term, in: fields) else { return nil }
            total += best
        }
        return total
    }
}
