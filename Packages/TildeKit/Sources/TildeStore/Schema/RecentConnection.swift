import Foundation
import SwiftData

/// A recent Quick Connect. Capped at 10 per device; pruning is done on read.
@Model
public final class RecentConnection {
    public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    /// e.g. `deploy@10.0.4.12:2222`.
    public var target: String = ""
    public var lastUsedAt: Date = Date.now
    @Relationship(deleteRule: .nullify, inverse: \Server.recents)
    public var server: Server?

    public init(target: String = "", lastUsedAt: Date = Date.now) {
        self.target = target
        self.lastUsedAt = lastUsedAt
    }
}
