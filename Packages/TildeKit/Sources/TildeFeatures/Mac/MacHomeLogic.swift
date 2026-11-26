import Foundation
import TildeCore
import TildeDesign
import TildeStore

// The decisions behind the Mac start page, kept apart from the views so they can be tested. They work on plain values
// and compile on every platform; only `MacHomeView` itself is Mac-only.

/// One saved server as the start page needs it.
struct HomeServer: Equatable, Identifiable {
    let id: UUID
    let name: String
    /// `deploy@10.0.1.12` or `deploy@10.0.1.12:2222`.
    let address: String
    let environment: ServerEnvironment
    let lastConnectedAt: Date?
    /// What the reachability monitor probes for this server: its jump host when it has one, like the sidebar.
    let probeTarget: ConnectionTarget

    init(id: UUID, name: String, address: String, environment: ServerEnvironment, lastConnectedAt: Date?, probeTarget: ConnectionTarget) {
        self.id = id
        self.name = name
        self.address = address
        self.environment = environment
        self.lastConnectedAt = lastConnectedAt
        self.probeTarget = probeTarget
    }

    init(_ server: Server) {
        let base = "\(server.username)@\(server.host)"
        self.init(
            id: server.id,
            name: ServerMapper.displayName(server),
            address: server.port == 22 ? base : "\(base):\(server.port)",
            environment: ServerMapper.environment(server),
            lastConnectedAt: server.lastConnectedAt,
            probeTarget: ServerMapper.target(server.jumpServer ?? server)
        )
    }
}

enum HomeLogic {
    /// How many rows the Recent table shows.
    static let recentLimit = 8

    /// Servers that were connected to, newest first (ties by name so the order is stable). Never connected: left out.
    static func recent(_ servers: [HomeServer], limit: Int = recentLimit) -> [HomeServer] {
        let used = servers.filter { $0.lastConnectedAt != nil }
        let sorted = used.sorted { a, b in
            if a.lastConnectedAt != b.lastConnectedAt { return (a.lastConnectedAt ?? .distantPast) > (b.lastConnectedAt ?? .distantPast) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return Array(sorted.prefix(limit))
    }

    /// What Return does in the Quick Connect field.
    enum Submit: Equatable {
        case connect
        case open(UUID)
        case nothing
    }

    /// Mirrors the sidebar search: text that looks like an address (or matches no saved server) connects to it; a word
    /// that matches a saved server opens the best match.
    /// - Parameters:
    ///   - parses: the text parses as a connection target.
    ///   - firstMatch: the best saved-server match for the text.
    static func submit(text: String, parses: Bool, firstMatch: UUID?) -> Submit {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .nothing }
        let looksLikeTarget = trimmed.contains("@") || trimmed.contains(":") || trimmed.contains(".") || trimmed.hasPrefix("ssh")
        let candidate = parses && (looksLikeTarget || firstMatch == nil)
        if candidate, firstMatch == nil || trimmed.contains("@") || trimmed.contains(":") { return .connect }
        if let firstMatch { return .open(firstMatch) }
        return candidate ? .connect : .nothing
    }

    /// The banner line after a tab closed: `prod-api-01: shell exited (0), tab closed`.
    static func message(for closure: ClosedSession) -> String {
        let name = closure.server.name
        switch closure.reason {
        case .exited(let status):
            return "\(name): shell exited\(status.map { " (\($0))" } ?? ""), tab closed"
        case .userClosed:
            return "\(name): tab closed"
        case .error(let error):
            return "\(name): \(SessionErrorCopy.present(error, server: closure.server).headline), tab closed"
        }
    }
}

/// One environment card: how many servers, and how many of them answer.
struct EnvironmentSummary: Equatable, Identifiable {
    enum Level: Equatable { case ok, slow, down, unknown }

    let environment: ServerEnvironment
    let count: Int
    let reachable: Int
    let slow: Int
    let down: Int

    var id: ServerEnvironment { environment }

    var level: Level {
        if down > 0 { .down } else if slow > 0 { .slow } else if reachable == count { .ok } else { .unknown }
    }

    /// `1 down, 2 slow`, `All reachable`, `Not checked`, or `3 of 5 reachable` while some are still unchecked.
    var label: String {
        var parts: [String] = []
        if down > 0 { parts.append("\(down) down") }
        if slow > 0 { parts.append("\(slow) slow") }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        if reachable == count { return "All reachable" }
        if reachable == 0 { return "Not checked" }
        return "\(reachable) of \(count) reachable"
    }

    /// One summary per environment that has servers, Production first.
    static func summaries(_ entries: [(environment: ServerEnvironment, status: ReachabilityMonitor.Status)]) -> [EnvironmentSummary] {
        let order: [ServerEnvironment] = [.prod, .staging, .dev, .lab, .none]
        return order.compactMap { environment in
            let members = entries.filter { $0.environment == environment }.map(\.status)
            guard !members.isEmpty else { return nil }
            var reachable = 0, slow = 0, down = 0
            for status in members {
                switch status {
                case .reachable(let ms):
                    if StatusDot.Kind(latencyMilliseconds: ms) == .slow { slow += 1 } else { reachable += 1 }
                case .unreachable:
                    down += 1
                case .unknown, .probing:
                    break
                }
            }
            return EnvironmentSummary(environment: environment, count: members.count, reachable: reachable, slow: slow, down: down)
        }
    }
}
