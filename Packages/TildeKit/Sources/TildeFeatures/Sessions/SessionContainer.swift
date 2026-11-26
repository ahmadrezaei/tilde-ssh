import SwiftUI
import TildeCore
import TildeDesign

/// iPad/Mac detail column: the tab strip over the stack of terminals. Reads the window's tabs from the
/// `SessionCoordinator` through the `AppNavigator`, so `SessionContainer()` works anywhere inside a `WindowHost`.
///
/// It also owns the window chrome that belongs to the session: the title (server name) and subtitle (`user@host`), and
/// the toolbar with the connection readout, Snippets and New Tab.
public struct SessionContainer: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    public init() {}

    public var body: some View {
        let tabs = navigator.tabs
        let selected = navigator.selectedTab
        VStack(spacing: 0) {
            if !tabs.isEmpty {
                TabStrip(tabs: tabs, selectedID: selected?.id)
            }
            ZStack {
                SessionStack(tabs: tabs, selectedID: selected?.id)
                if tabs.isEmpty {
                    EmptyState("No open sessions", message: "Pick a server on the left, or press ⌘T to connect.") {
                        Button("Quick Connect") { navigator.present(.palette(.newTab)) }.buttonStyle(.tildePrimary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TildeColor.bg.ignoresSafeArea())
        .navigationTitle(selected?.title ?? "Tilde")
        .navigationSubtitle(selected.map(Self.subtitle) ?? "")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        // The container paints the same background under the bar, so the bar reads as one surface with the strip below.
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #endif
        .toolbar { sessionToolbar(selected: selected) }
    }

    /// `deploy@10.0.1.12`, with `:port` only when it is not 22.
    static func subtitle(for tab: SessionTab) -> String {
        let target = tab.server.target
        let port = target.port == 22 ? "" : ":\(target.port)"
        return "\(target.username)@\(target.host)\(port)"
    }

    // MARK: Toolbar

    /// Status first, then Snippets and New Tab as two buttons of their own. A fixed `ToolbarSpacer` between items keeps
    /// the glass capsules apart; without one, neighbouring items merge into a single crowded group.
    @ToolbarContentBuilder
    private func sessionToolbar(selected: SessionTab?) -> some ToolbarContent {
        if let tab = selected {
            ToolbarItem(placement: .primaryAction) {
                SessionStatusReadout(tab: tab)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { navigator.present(.palette(.snippets)) } label: { Image(systemName: "bolt") }
                .accessibilityLabel("Snippets")
                .help("Snippets (⇧⌘S)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { navigator.present(.palette(.newTab)) } label: { Image(systemName: "plus") }
                .accessibilityLabel("New tab")
                .help("New tab (⌘T)")
        }
    }
}

/// `● 23 ms`, or what the session is doing instead of a latency: connecting, reconnecting, disconnected.
struct SessionStatusReadout: View {
    let tab: SessionTab

    var body: some View {
        switch tab.state {
        case .idle, .connecting:
            StatusReadout(.busy, text: "Connecting…")
        case .reconnecting:
            StatusReadout(.slow, text: "Reconnecting…")
        case .disconnected(let reason):
            if case .error = reason {
                StatusReadout(.bad, text: "Connection failed")
            } else {
                StatusReadout(.idle, text: "Disconnected")
            }
        case .connected:
            if let ms = tab.latencyMilliseconds {
                StatusReadout(StatusReadout.Quality(latencyMilliseconds: ms), text: "\(ms) ms", accessibilityText: "Latency \(ms) milliseconds")
            } else {
                StatusReadout(.good, text: "Connected")
            }
        }
    }
}

#Preview("SessionContainer") {
    TildePreviewHost { _ in SessionContainer() }
}
