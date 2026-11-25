import SwiftUI

/// Identifies the session shown in a detached session window: `WindowGroup(id: "session", for: SessionWindowValue.self)`.
///
/// This is the value `openWindow(id:value:)` carries when a tab is moved to a new window (Window > Move Tab to
/// New Window). It holds only the session's identifier, so it is safe to persist for window restoration.
public struct SessionWindowValue: Codable, Hashable, Sendable {
    /// The identifier of the session the window shows.
    public var sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}

/// A single detached session window (`WindowGroup(id: "session", for: SessionWindowValue.self)`).
///
/// Until the session coordinator can resolve `value.sessionID` to a live session (WS5), the window shows the
/// shared session container.
public struct SessionWindow: View {
    private let value: SessionWindowValue?

    /// - Parameter value: the session to show; `nil` shows the container's default content.
    public init(value: SessionWindowValue? = nil) {
        self.value = value
    }

    public var body: some View {
        SessionContainer()
    }
}
