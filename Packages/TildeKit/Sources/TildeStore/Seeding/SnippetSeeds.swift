import Foundation
import SwiftData
import TildeCore

/// The example snippets a fresh install starts with (docs/DESIGN.md section 4.8). Each has a fixed `seedID`
/// so the `Deduplicator` can merge copies that two devices seeded independently.
public enum SnippetSeeds {
    public struct Seed: Sendable, Equatable {
        public let seedID: String
        public let name: String
        public let command: String
        public let folder: String
        public let runMode: SnippetRunMode
    }

    /// Bump when new seeds are added; devices that already seeded an older version only insert the new ones.
    public static let version = 1

    public static let all: [Seed] = [
        Seed(seedID: "seed.journalctl-follow", name: "journalctl follow", command: #"sudo journalctl -u <unit> -f --since "10 min ago""#, folder: "Logs", runMode: .insert),
        Seed(seedID: "seed.kubectl-pods", name: "kubectl pods", command: "kubectl get pods -A -o wide", folder: "Kubernetes", runMode: .insertAndReturn),
        Seed(seedID: "seed.disk-and-memory", name: "disk and memory", command: "df -h && free -m", folder: "System", runMode: .insertAndReturn),
        Seed(seedID: "seed.listening-ports", name: "listening ports", command: "ss -tulpn", folder: "System", runMode: .insertAndReturn),
        Seed(seedID: "seed.docker-ps", name: "docker ps", command: #"docker ps --format 'table {{.Names}}\t{{.Status}}'"#, folder: "Docker", runMode: .insertAndReturn),
        Seed(seedID: "seed.tail-syslog", name: "tail syslog", command: "tail -f /var/log/syslog", folder: "Logs", runMode: .insertAndReturn),
        Seed(seedID: "seed.service-status", name: "service status", command: "systemctl status <unit>", folder: "System", runMode: .insert),
        Seed(seedID: "seed.htop", name: "htop", command: "htop", folder: "System", runMode: .insertAndReturn),
    ]

    /// Inserts the seeds whose `seedID` is not in the store yet. Safe to call repeatedly.
    ///
    /// - Returns: the number of snippets inserted.
    @MainActor
    @discardableResult
    public static func seedMissing(in context: ModelContext) throws -> Int {
        let existing = Set(try context.fetch(FetchDescriptor<Snippet>()).compactMap(\.seedID))
        var inserted = 0
        for (index, seed) in all.enumerated() where !existing.contains(seed.seedID) {
            let snippet = Snippet(name: seed.name, command: seed.command, runModeRaw: seed.runMode.rawValue, seedID: seed.seedID)
            snippet.folder = seed.folder
            snippet.sortIndex = FractionalOrder.step * Double(index + 1)
            context.insert(snippet)
            inserted += 1
        }
        if inserted > 0 { try context.save() }
        return inserted
    }

    /// Seeds once per device and seed version, so a snippet the user deleted does not come back.
    /// The marker lives in local `UserDefaults` (it is deliberately not synced: another device may not have
    /// received the synced snippets yet, and the `Deduplicator` merges any duplicates).
    @MainActor
    @discardableResult
    public static func seedIfNeeded(in context: ModelContext, defaults: UserDefaults = .standard) throws -> Int {
        let key = "tilde.snippetSeedVersion"
        guard defaults.integer(forKey: key) < version else { return 0 }
        let inserted = try seedMissing(in: context)
        defaults.set(version, forKey: key)
        return inserted
    }
}
