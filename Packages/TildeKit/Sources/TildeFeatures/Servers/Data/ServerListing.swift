import Foundation
import TildeStore

/// What the server list needs to know about a server to filter, order and group it. `Server` conforms; tests use a
/// plain value type, so none of this needs SwiftData.
protocol ServerListable {
    var listID: UUID { get }
    /// The name shown in the list (the host when the name is empty).
    var listDisplayName: String { get }
    /// The raw name, used as the manual-order tiebreak.
    var listName: String { get }
    var listSortIndex: Double { get }
    var listLastConnectedAt: Date? { get }
    var listIsFavorite: Bool { get }
    var listGroupID: UUID? { get }
    var listSearchItem: ServerSearchItem { get }
}

/// Servers split into their groups and the rest. Every server is in exactly one bucket.
struct ServerSections<Item> {
    /// Per group id. Groups without servers are present and empty.
    var groups: [UUID: [Item]]
    /// Servers without a group, or whose group is not in the caller's list (a sync race can create those).
    var ungrouped: [Item]
}

/// Filtering, ordering and grouping shared by the iPhone / iPad server list and the Mac sidebar (design section 4.1).
enum ServerListing {
    /// Orders `servers` for display. `favoritesFirst` floats favorites to the top, keeping the order inside each half.
    static func sorted<S: ServerListable>(_ servers: [S], mode: ServerSortMode, favoritesFirst: Bool = false) -> [S] {
        let ordered: [S]
        switch mode {
        case .manual:
            ordered = servers.sorted { ($0.listSortIndex, $0.listName) < ($1.listSortIndex, $1.listName) }
        case .name:
            ordered = servers.sorted { $0.listDisplayName.localizedStandardCompare($1.listDisplayName) == .orderedAscending }
        case .lastUsed:
            ordered = servers.sorted { ($0.listLastConnectedAt ?? .distantPast) > ($1.listLastConnectedAt ?? .distantPast) }
        }
        guard favoritesFirst else { return ordered }
        return ordered.filter(\.listIsFavorite) + ordered.filter { !$0.listIsFavorite }
    }

    /// The servers that match `query`, best match first; equal scores fall back to the display name.
    static func ranked<S: ServerListable>(_ servers: [S], query: ServerQuery) -> [S] {
        var scored: [(server: S, score: Int)] = []
        for server in servers {
            if let score = query.score(server.listSearchItem) { scored.append((server, score)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.server.listDisplayName.localizedStandardCompare(rhs.server.listDisplayName) == .orderedAscending
        }
        return scored.map(\.server)
    }

    /// The servers that match `query`, in their original order.
    static func filtered<S: ServerListable>(_ servers: [S], query: ServerQuery) -> [S] {
        query.isEmpty ? servers : servers.filter { query.score($0.listSearchItem) != nil }
    }

    /// Buckets `servers` into `groupIDs` and ungrouped, ordering each bucket with `sorted`.
    static func sections<S: ServerListable>(
        _ servers: [S], groupIDs: [UUID], mode: ServerSortMode, favoritesFirst: Bool
    ) -> ServerSections<S> {
        let known = Set(groupIDs)
        var buckets: [UUID: [S]] = [:]
        var rest: [S] = []
        for server in servers {
            if let id = server.listGroupID, known.contains(id) { buckets[id, default: []].append(server) } else { rest.append(server) }
        }
        var groups: [UUID: [S]] = [:]
        for id in groupIDs { groups[id] = sorted(buckets[id] ?? [], mode: mode, favoritesFirst: favoritesFirst) }
        return ServerSections(groups: groups, ungrouped: sorted(rest, mode: mode, favoritesFirst: favoritesFirst))
    }

    // MARK: Quick Connect

    /// Whether search text that parsed as a target should be offered as one (not just a word that happens to match a
    /// server name).
    static func looksLikeTarget(_ trimmedText: String) -> Bool {
        trimmedText.contains("@") || trimmedText.contains(":") || trimmedText.contains(".") || trimmedText.hasPrefix("ssh")
    }

    /// What pressing return in the search field does.
    enum Submission: Equatable {
        case connect
        case openFirstResult
        case nothing
    }

    /// - Parameters:
    ///   - hasCandidate: the text parses as a target and looks like one (`looksLikeTarget`, or nothing else matches).
    ///   - rawText: the search text as typed (untrimmed).
    ///   - hasResults: whether any server matches.
    static func submission(hasCandidate: Bool, rawText: String, hasResults: Bool) -> Submission {
        if hasCandidate, !hasResults || rawText.contains("@") || rawText.contains(":") { return .connect }
        if hasResults { return .openFirstResult }
        return hasCandidate ? .connect : .nothing
    }
}

extension Server: ServerListable {
    var listID: UUID { id }
    var listDisplayName: String { ServerMapper.displayName(self) }
    var listName: String { name }
    var listSortIndex: Double { sortIndex }
    var listLastConnectedAt: Date? { lastConnectedAt }
    var listIsFavorite: Bool { isFavorite }
    var listGroupID: UUID? { group?.id }
    var listSearchItem: ServerSearchItem { searchItem }
}
