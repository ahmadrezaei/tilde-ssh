import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The verbs the menu bar and keyboard shortcuts call on the focused window. Published by `WindowHost` with
/// `focusedSceneValue`, so each window answers for itself. WS6's `MacCommands` can read the same value.
public struct SessionCommandActions {
    public var hasTabs: Bool
    public var canReopenClosed: Bool
    public var newTab: @MainActor () -> Void
    public var closeTab: @MainActor () -> Void
    public var reopenClosedTab: @MainActor () -> Void
    public var selectTab: @MainActor (Int) -> Void
    public var nextTab: @MainActor () -> Void
    public var previousTab: @MainActor () -> Void
    public var commandPalette: @MainActor () -> Void
    public var snippetPalette: @MainActor () -> Void
    public var quickConnect: @MainActor () -> Void
    public var newServer: @MainActor () -> Void
    public var reconnect: @MainActor () -> Void
    public var disconnect: @MainActor () -> Void
    public var showSettings: @MainActor () -> Void
}

public extension FocusedValues {
    @Entry var sessionActions: SessionCommandActions?
}

/// Keyboard shortcuts from design section 3.3 / 3.4: Cmd-T, Cmd-W, Cmd-1...9, Cmd-Shift-[ ], Cmd-L, Cmd-P, Cmd-Shift-S,
/// Cmd-R, Cmd-N (iPad) / Shift-Cmd-N (Mac) for a new server.
///
/// Cmd-K is left to the terminal (clear scrollback), as in Terminal.app and iTerm2; the palette is Cmd-P per the
/// design. Add this in the `App` scene with `.commands { SessionCommands() }`.
public struct SessionCommands: Commands {
    @FocusedValue(\.sessionActions) private var actions

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") { actions?.newTab() }
                .keyboardShortcut("t")
                .disabled(actions == nil)
            #if os(macOS)
            Button("New Server…") { actions?.newServer() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            #else
            Button("New Server…") { actions?.newServer() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            #endif
            Button("Quick Connect") { actions?.quickConnect() }
                .keyboardShortcut("l")
                .disabled(actions == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { actions?.closeTab() }
                .keyboardShortcut("w")
                .disabled(actions?.hasTabs != true)
            Button("Reopen Closed Tab") { actions?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(actions?.canReopenClosed != true)
            #if os(macOS)
            Button("Close Window") { NSApplication.shared.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            #endif
        }

        CommandGroup(replacing: .printItem) {
            Button("Command Palette…") { actions?.commandPalette() }
                .keyboardShortcut("p")
                .disabled(actions == nil)
            Button("Snippets…") { actions?.snippetPalette() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }

        CommandGroup(after: .windowArrangement) {
            Button("Previous Tab") { actions?.previousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(actions?.hasTabs != true)
            Button("Next Tab") { actions?.nextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(actions?.hasTabs != true)
            Divider()
            ForEach(1...9, id: \.self) { index in
                Button("Tab \(index)") { actions?.selectTab(index) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: .command)
                    .disabled(actions?.hasTabs != true)
            }
        }

        CommandMenu("Session") {
            Button("Reconnect") { actions?.reconnect() }
                .keyboardShortcut("r")
                .disabled(actions?.hasTabs != true)
            Button("Disconnect") { actions?.disconnect() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(actions?.hasTabs != true)
        }
    }
}
