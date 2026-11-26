import SwiftUI
import TildeCore
import TildeDesign

/// iPad/Mac detail column: the tab strip over the stack of terminals. Reads the window's tabs from the
/// `SessionCoordinator` through the `AppNavigator`, so `SessionContainer()` works anywhere inside a `WindowHost`.
///
/// It also owns the window chrome that belongs to the session: the title (server name) and subtitle (`user@host`), and
/// the toolbar with the connection readout, Snippets and New Tab. On the Mac the title is drawn in SF Mono with a
/// compact environment badge, Snippets and New Tab share one glass group, and the readout lives in the status bar
/// at the bottom instead.
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
                    #if os(macOS)
                    MacHomeView()
                    #else
                    EmptyState("No open sessions", message: "Pick a server on the left, or press ⌘T to connect.") {
                        Button("Quick Connect") { navigator.present(.palette(.newTab)) }.buttonStyle(.tildePrimary)
                    }
                    #endif
                }
            }
            #if os(macOS)
            if let selected {
                SessionStatusBar(tab: selected)
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TildeColor.bg.ignoresSafeArea())
        .navigationTitle(selected?.title ?? "Tilde")
        .navigationSubtitle(selected.map { Self.subtitle(for: $0.server.target) } ?? "")
        #if os(macOS)
        // The toolbar draws its own title (see `sessionToolbar`) while a session is open; `navigationTitle` still names
        // the window for the Window menu and VoiceOver. Passing `nil` keeps the view tree (and the terminals) stable.
        .toolbar(removing: selected == nil ? nil : .title)
        #else
        .navigationBarTitleDisplayMode(.inline)
        // The container paints the same background under the bar, so the bar reads as one surface with the strip below.
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #endif
        .toolbar { sessionToolbar(selected: selected) }
        // The last tab closed (Disconnect, `exit`): bring the server list back.
        .onChange(of: tabs.isEmpty) { _, isEmpty in
            if isEmpty { navigator.columnVisibility = .all }
        }
    }

    /// `deploy@10.0.1.12`, with `:port` only when it is not 22.
    static func subtitle(for target: ConnectionTarget) -> String {
        let port = target.port == 22 ? "" : ":\(target.port)"
        return "\(target.username)@\(target.host)\(port)"
    }

    /// `deploy@10.0.1.12 · via bastion`: the toolbar subtitle on the Mac.
    static func macSubtitle(for server: ServerSnapshot) -> String {
        let address = subtitle(for: server.target)
        guard let jump = server.jump else { return address }
        return "\(address) · via \(jump.target.host)"
    }

    // MARK: Toolbar

    #if os(macOS)
    /// Title and badge on the left, then Snippets and New Tab as one grouped item (one glass capsule).
    @ToolbarContentBuilder
    private func sessionToolbar(selected: SessionTab?) -> some ToolbarContent {
        if let tab = selected {
            ToolbarItem(placement: .navigation) {
                SessionToolbarTitle(tab: tab)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        // On macOS `.primaryAction` sits at the leading edge; the flexible spacer pushes the group to the trailing edge.
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .automatic) {
            Button { navigator.present(.palette(.snippets)) } label: { Image(systemName: "bolt") }
                .accessibilityLabel("Snippets")
                .help("Snippets (⇧⌘S)")
            Button { navigator.present(.palette(.newTab)) } label: { Image(systemName: "plus") }
                .accessibilityLabel("New tab")
                .help("New tab (⌘T)")
        }
    }
    #else
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
    #endif
}

#if os(macOS)
/// The Mac toolbar title: the server name in SF Mono with a compact environment badge, and the address (plus
/// `via <jump host>`) as the subtitle underneath.
struct SessionToolbarTitle: View {
    let tab: SessionTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(tab.title)
                    .tildeMono(13, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(TildeColor.text)
                    .lineLimit(1)
                EnvBadge(tab.tone)
            }
            Text(SessionContainer.macSubtitle(for: tab.server))
                .tildeMono(11, relativeTo: .caption)
                .foregroundStyle(TildeColor.text2)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
#endif

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
