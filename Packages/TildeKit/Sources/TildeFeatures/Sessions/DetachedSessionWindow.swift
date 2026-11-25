import SwiftUI
import TildeDesign

/// A window that shows the single tab moved out with "Open in New Window". The tab's id is the window id, so the
/// window shows exactly that tab; when it closes, the window goes with it.
///
/// Scene: `WindowGroup("Session", id: "session", for: UUID.self) { $id in DetachedSessionWindow(tabID: id) }`
/// (declared in `TildeApp`). WS6's `SessionWindow` placeholder can adopt this.
public struct DetachedSessionWindow: View {
    private let tabID: UUID?

    public init(tabID: UUID?) { self.tabID = tabID }

    public var body: some View {
        WindowHost(windowID: tabID) {
            DetachedContent()
        }
        .background(TildeColor.bg)
        .tint(TildeColor.accent)
    }
}

private struct DetachedContent: View {
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        SessionContainer()
            .onChange(of: navigator.tabs.isEmpty) { _, isEmpty in
                if isEmpty { dismissWindow() }
            }
    }
}
