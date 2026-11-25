import Foundation
import SwiftData

@Model
public final class ServerGroup {
    public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var updatedAt: Date = Date.now

    public var name: String = ""
    /// SF Symbol name.
    public var symbol: String = "folder"
    public var sortIndex: Double = 0
    /// Synced intentionally, so a collapsed group stays collapsed on every device.
    public var isCollapsed: Bool = false
    /// Inverse is declared on `Server.group`.
    public var servers: [Server]? = []

    public init(name: String = "", symbol: String = "folder", sortIndex: Double = 0) {
        self.name = name
        self.symbol = symbol
        self.sortIndex = sortIndex
    }
}
