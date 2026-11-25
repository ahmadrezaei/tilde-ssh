import SwiftUI
import TildeCore
import TildeDesign

/// Every open tab of a window, stacked. Only the selected one is visible and hit-testable, but all stay in the view
/// tree, so each terminal keeps its scrollback and byte stream when you switch tabs.
struct SessionStack: View {
    let tabs: [SessionTab]
    let selectedID: UUID?

    var body: some View {
        ZStack {
            ForEach(tabs) { tab in
                let isSelected = tab.id == selectedID
                SessionScreen(tab: tab)
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                    .zIndex(isSelected ? 1 : 0)
            }
        }
    }
}

/// Context-menu / `…`-menu entries shared by the title bar and the tab strip.
struct SessionMenuItems: View {
    let tab: SessionTab
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        Button { navigator.present(.palette(.snippets)) } label: { Label("Snippets…", systemImage: "bolt") }
        Button { coordinator.reconnect(tab) } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
        Button { Platform.copy(SSHCommand.string(for: tab.server)) } label: { Label("Copy SSH Command", systemImage: "doc.on.doc") }
        if tab.isAdHoc {
            Button { navigator.saveAsServer(tab) } label: { Label("Save as Server…", systemImage: "square.and.arrow.down") }
        } else {
            Button { navigator.present(.editServer(tab.server.id)) } label: { Label("Edit Server…", systemImage: "pencil") }
        }
        Divider()
        Button(role: .destructive) { coordinator.close(tab) } label: { Label("Disconnect", systemImage: "xmark.circle") }
    }
}
