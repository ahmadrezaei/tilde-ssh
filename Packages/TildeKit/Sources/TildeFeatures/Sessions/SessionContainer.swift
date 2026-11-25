import SwiftUI
import TildeCore
import TildeDesign

/// iPad/Mac detail column: the tab strip over the stack of terminals. Reads the window's tabs from the
/// `SessionCoordinator` through the `AppNavigator`, so `SessionContainer()` works anywhere inside a `WindowHost`.
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
        .background(TildeColor.bg)
    }
}

/// The in-window tab strip (design sections 3.3 and 3.4): env stripe on top of every tab, status dot, title,
/// close button, and a `+` button.
struct TabStrip: View {
    let tabs: [SessionTab]
    let selectedID: UUID?
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        TabStripItem(tab: tab, index: index + 1, isSelected: tab.id == selectedID)
                    }
                }
            }
            Button { navigator.present(.palette(.newTab)) } label: {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 36, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(TildeColor.text2)
            .accessibilityLabel("New tab")
        }
        .frame(height: 34)
        .background(TildeColor.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(TildeColor.border).frame(height: TildeSpacing.hairline) }
    }
}

private struct TabStripItem: View {
    let tab: SessionTab
    let index: Int
    let isSelected: Bool
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            EnvStripe(tab.tone)
            HStack(spacing: 6) {
                StatusDot(tab.isLive && tab.isConnected ? .live : tab.statusKind)
                Text(tab.title)
                    .tildeMono(12, weight: isSelected ? .semibold : .regular, relativeTo: .footnote)
                    .lineLimit(1)
                Button { coordinator.close(tab) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .foregroundStyle(TildeColor.text3)
                .accessibilityLabel("Close \(tab.title)")
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 110, maxWidth: 220)
        .foregroundStyle(isSelected ? TildeColor.text : TildeColor.text2)
        .background(isSelected ? TildeColor.bg : TildeColor.surface2.opacity(0.6))
        .overlay(alignment: .bottom) {
            if isSelected { Rectangle().fill(TildeColor.accent).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { coordinator.select(tab) }
        .contextMenu {
            SessionMenuItems(tab: tab)
            Button {
                let id = coordinator.moveToOwnWindow(tab)
                openWindow(id: "session", value: id)
            } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tab \(index), \(tab.title)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("SessionContainer") {
    TildePreviewHost { _ in SessionContainer() }
}
