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
        #if os(macOS)
        // Only the visible tab's terminal may hold the keyboard, and not while its host-key card is up: otherwise a
        // closing sheet can hand focus back to a hidden tab and typing reaches a shell nobody is looking at.
        .onChange(of: keyboardTabID, initial: true) { _, id in
            for tab in tabs { tab.terminal.acceptsKeyboardFocus = tab.id == id }
            // A host-key card just went away: give its terminal the keyboard back.
            if let id, let tab = tabs.first(where: { $0.id == id }), tab.isConnected {
                DispatchQueue.main.async { tab.terminal.focus() }
            }
        }
        #endif
        // Give the terminal the keyboard as soon as there is a shell to type into, and again on every tab switch, so
        // nobody has to click into it first.
        .onChange(of: focusTarget, initial: true) { _, target in
            guard let target, target.isConnected, let tab = tabs.first(where: { $0.id == target.id }) else { return }
            // Next turn of the run loop: the terminal view is in its window by then.
            DispatchQueue.main.async { tab.terminal.focus() }
        }
    }

    #if os(macOS)
    @Environment(SessionCoordinator.self) private var coordinator

    /// The tab whose terminal may take the keyboard: the visible one, unless a host-key question is shown over it.
    private var keyboardTabID: UUID? {
        guard let selected = tabs.first(where: { $0.id == selectedID }) ?? tabs.last else { return nil }
        return coordinator.pendingInTabHostKey(for: selected.id) == nil ? selected.id : nil
    }
    #endif

    private struct FocusTarget: Equatable {
        let id: UUID
        let isConnected: Bool
    }

    private var focusTarget: FocusTarget? {
        let selected = tabs.first { $0.id == selectedID } ?? tabs.last
        return selected.map { FocusTarget(id: $0.id, isConnected: $0.isConnected) }
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
