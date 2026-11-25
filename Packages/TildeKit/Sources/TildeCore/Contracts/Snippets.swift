import Foundation

// MARK: - Key bar (WS4) <-> snippets (WS1 data, WS5 palette)

public protocol SnippetProviding: Sendable {
    func snippets(matching query: String) async -> [SnippetSnapshot]
}

public struct SnippetSnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var command: String
    /// `true` = insert and press Return (`runMode == insertAndReturn`).
    public var runOnInsert: Bool

    public init(id: UUID = UUID(), name: String, command: String, runOnInsert: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.runOnInsert = runOnInsert
    }
}
