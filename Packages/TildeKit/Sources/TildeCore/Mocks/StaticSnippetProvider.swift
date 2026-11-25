import Foundation

/// A `SnippetProviding` over a fixed list. The default list mirrors the 8 seeded examples from the design
/// spec (section 4.8).
public struct StaticSnippetProvider: SnippetProviding {
    public var all: [SnippetSnapshot]

    public init(_ snippets: [SnippetSnapshot] = StaticSnippetProvider.seeded) {
        self.all = snippets
    }

    public func snippets(matching query: String) async -> [SnippetSnapshot] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) || $0.command.lowercased().contains(q) }
    }

    public static let seeded: [SnippetSnapshot] = [
        ("journalctl follow", #"sudo journalctl -u <unit> -f --since "10 min ago""#, false),
        ("kubectl pods", "kubectl get pods -A -o wide", true),
        ("disk and memory", "df -h && free -m", true),
        ("listening ports", "ss -tulpn", true),
        ("docker ps", #"docker ps --format 'table {{.Names}}\t{{.Status}}'"#, true),
        ("tail syslog", "tail -f /var/log/syslog", true),
        ("service status", "systemctl status <unit>", false),
        ("htop", "htop", true),
    ].enumerated().map { index, item in
        SnippetSnapshot(
            id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1))!,
            name: item.0, command: item.1, runOnInsert: item.2
        )
    }
}
