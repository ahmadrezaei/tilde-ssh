import Foundation
import SwiftData

@Model
public final class Snippet {
    public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public var name: String = ""
    public var command: String = ""
    public var folder: String?
    public var isFavorite: Bool = false
    public var sortIndex: Double = 0
    /// `insert` / `insertAndReturn`.
    public var runModeRaw: String = "insert"
    /// nil = global. CloudKit requires an inverse, which lives on `Server.snippets`.
    @Relationship(deleteRule: .nullify, inverse: \Server.snippets)
    public var scopeServer: Server?
    /// Used for deduplicating seeded examples.
    public var seedID: String?

    public init(name: String = "", command: String = "", runModeRaw: String = "insert", seedID: String? = nil) {
        self.name = name
        self.command = command
        self.runModeRaw = runModeRaw
        self.seedID = seedID
    }
}
