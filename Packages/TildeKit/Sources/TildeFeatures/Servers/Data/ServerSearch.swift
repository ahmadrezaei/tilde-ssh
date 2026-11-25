import Foundation
import TildeCore

/// Subsequence ("fuzzy") matching used by the server list search and the command palette.
enum Fuzzy {
    /// A score (higher is better), or `nil` when `query` does not match `text`. An empty query matches with 0.
    /// Substring hits beat scattered subsequence hits; prefix hits beat both.
    static func score(_ query: String, in text: String) -> Int? {
        let q = query.lowercased()
        guard !q.isEmpty else { return 0 }
        let t = text.lowercased()
        if let range = t.range(of: q) {
            let offset = t.distance(from: t.startIndex, to: range.lowerBound)
            return 1000 - offset + (offset == 0 ? 200 : 0)
        }
        var score = 0
        var streak = 0
        var searchStart = t.startIndex
        for ch in q {
            guard let found = t[searchStart...].firstIndex(of: ch) else { return nil }
            streak = (found == searchStart && score > 0) ? streak + 1 : 0
            score += 10 + streak * 5
            searchStart = t.index(after: found)
        }
        return score
    }
}

/// The searchable fields of one server (decoupled from SwiftData so matching is unit-testable).
struct ServerSearchItem: Equatable {
    var name: String
    var host: String
    var username: String
    var tags: [String]
    var groupName: String?
    var environment: ServerEnvironment
}

/// A parsed search string: free text plus `#tag` and `env:prod` filters (design section 4.1).
struct ServerQuery: Equatable {
    var words: [String] = []
    var tags: Set<String> = []
    var environment: ServerEnvironment?

    init(parsing raw: String, selectedTags: Set<String> = []) {
        tags = Set(selectedTags.map { $0.lowercased() })
        for token in raw.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.hasPrefix("#"), token.count > 1 {
                tags.insert(String(token.dropFirst()).lowercased())
            } else if token.lowercased().hasPrefix("env:") {
                environment = Self.environment(named: String(token.dropFirst(4)))
            } else {
                words.append(token)
            }
        }
    }

    /// `true` when nothing filters.
    var isEmpty: Bool { words.isEmpty && tags.isEmpty && environment == nil }

    private static func environment(named name: String) -> ServerEnvironment? {
        switch name.lowercased() {
        case "prod", "production": .prod
        case "stg", "staging", "stage": .staging
        case "dev", "development": .dev
        case "lab", "homelab": .lab
        case "none": ServerEnvironment.none
        default: nil
        }
    }

    /// `nil` excludes the item; otherwise a relevance score (higher first).
    func score(_ item: ServerSearchItem) -> Int? {
        if let environment, item.environment != environment { return nil }
        let itemTags = Set(item.tags.map { $0.lowercased() })
        guard tags.isSubset(of: itemTags) else { return nil }
        var total = 0
        for word in words {
            let candidates: [Int?] = [
                Fuzzy.score(word, in: item.name).map { $0 + 50 },
                Fuzzy.score(word, in: item.host),
                Fuzzy.score(word, in: item.username).map { $0 - 100 },
                item.groupName.flatMap { Fuzzy.score(word, in: $0).map { $0 - 150 } },
                itemTags.compactMap { Fuzzy.score(word, in: $0) }.max().map { $0 - 100 },
            ]
            guard let best = candidates.compactMap({ $0 }).max() else { return nil }
            total += best
        }
        return total
    }
}
