import Foundation
import SwiftData

@Model
public final class Tag {
    public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    /// Case-insensitive deduplication is done by the `Deduplicator`, since CloudKit forbids unique constraints.
    public var name: String = ""
    public var colorHex: String?
    /// Inverse is declared on `Server.tags` (many-to-many).
    public var servers: [Server]? = []

    public init(name: String = "", colorHex: String? = nil) {
        self.name = name
        self.colorHex = colorHex
    }
}
