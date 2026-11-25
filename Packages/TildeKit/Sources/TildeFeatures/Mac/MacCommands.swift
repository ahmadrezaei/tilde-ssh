import SwiftUI

#if os(macOS)
import AppKit
#endif

/// The Mac (and iPadOS 26) menu bar: File, Edit, View, Session and Window (docs/DESIGN.md section 3.4).
///
/// The commands carry no state of their own. They read ``WindowCommandActions`` and ``SessionCommandActions``
/// from the focused scene (published with `.windowCommandActions(_:)` and `.sessionCommandActions(_:)`) and
/// disable every item whose closure is `nil`.
///
/// Shortcut notes:
/// - ⌘N (New Window) is the system's own item for a `WindowGroup`; Tilde adds New Server on ⇧⌘N next to it.
/// - ⌘K clears the scrollback, as in Terminal and iTerm2. Quick Connect is ⌘L and ⌘T opens a new tab.
/// - The terminal keeps ⌃C and ⌃D for itself; "Send Ctrl-C" in the Session menu exists for the pointer.
public struct MacCommands: Commands {
    @FocusedValue(\.windowCommands) private var window
    @FocusedValue(\.sessionCommands) private var session
    @AppStorage(SecureKeyboardEntry.defaultsKey) private var secureKeyboardEntry = false

    /// Creates the command set. Add it once: `WindowGroup { ... }.commands { MacCommands() }`.
    public init() {}

    public var body: some Commands {
        fileMenu
        editMenu
        viewMenu
        sessionMenu
        windowMenu
        appMenu
    }

    // MARK: File

    @CommandsBuilder private var fileMenu: some Commands {
        CommandGroup(after: .newItem) {
            item("New Tab", window?.newTab).keyboardShortcut("t")
            item("Reopen Closed Tab", window?.reopenClosedTab).keyboardShortcut("t", modifiers: [.command, .shift])
            item("New Server…", window?.newServer).keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            item("Quick Connect", window?.quickConnect).keyboardShortcut("l")
            item("Command Palette…", window?.commandPalette).keyboardShortcut("p")
            Divider()
            item("Import from ~/.ssh/config…", window?.importSSHConfig)
            item("Import known_hosts…", window?.importKnownHosts)
        }

        // Replacing `.saveItem` also removes the system "Close" item, so both close commands live here.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { closeTab() }
                .keyboardShortcut("w")
            Button("Close Window") { closeWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
    }

    // MARK: Edit

    @CommandsBuilder private var editMenu: some Commands {
        CommandGroup(after: .pasteboard) {
            item("Paste Snippet…", session?.pasteSnippet).keyboardShortcut("s", modifiers: [.command, .shift])
        }

        // `.textEditing` is where AppKit puts its own Find submenu (⌘F, ⌘G) for text views. Replacing the group
        // means those shortcuts belong to the terminal find bar only and never appear twice in the Edit menu.
        CommandGroup(replacing: .textEditing) {
            item("Find…", session?.find).keyboardShortcut("f")
            item("Find Next", session?.findNext).keyboardShortcut("g")
            item("Find Previous", session?.findPrevious).keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }

    // MARK: View

    @CommandsBuilder private var viewMenu: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") { toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            item("Bigger", window?.increaseFontSize).keyboardShortcut("+")
            item("Smaller", window?.decreaseFontSize).keyboardShortcut("-")
            item("Actual Size", window?.resetFontSize).keyboardShortcut("0")
            Divider()
            themeMenu
        }
    }

    private var themeMenu: some View {
        Menu("Theme") {
            let themes = window?.themes ?? []
            ForEach(themes) { theme in
                Toggle(theme.name, isOn: Binding(
                    get: { window?.selectedThemeID == theme.id },
                    set: { _ in window?.selectTheme?(theme.id) }
                ))
            }
        }
        .disabled((window?.themes.isEmpty ?? true) || window?.selectTheme == nil)
    }

    // MARK: Session

    @CommandsBuilder private var sessionMenu: some Commands {
        CommandMenu("Session") {
            item("Reconnect", session?.reconnect).keyboardShortcut("r")
            item("Disconnect", session?.disconnect).keyboardShortcut("w", modifiers: [.command, .option])
            Divider()
            item("Clear Scrollback", session?.clearScrollback).keyboardShortcut("k")
            item("Send Ctrl-C", session?.sendInterrupt)
            item("Send Break", session?.sendBreak)
            Divider()
            #if os(macOS)
            Toggle("Secure Keyboard Entry", isOn: Binding(
                get: { secureKeyboardEntry },
                set: { newValue in
                    secureKeyboardEntry = newValue
                    SecureKeyboardEntry.shared.apply()
                }
            ))
            Divider()
            #endif
            item("Edit Server…", session?.editServer)
            item("Copy SSH Command", session?.copySSHCommand).keyboardShortcut("c", modifiers: [.command, .option])
        }
    }

    // MARK: Window

    @CommandsBuilder private var windowMenu: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
            item("Previous Tab", window?.selectPreviousTab).keyboardShortcut("[", modifiers: [.command, .shift])
            item("Next Tab", window?.selectNextTab).keyboardShortcut("]", modifiers: [.command, .shift])
            item("Move Tab to New Window", window?.moveTabToNewWindow)
            Divider()
            ForEach(1...9, id: \.self) { digit in
                Button("Tab \(digit)") { selectTab(digit: digit) }
                    .keyboardShortcut(KeyEquivalent(Character(String(digit))), modifiers: .command)
                    .disabled(TabShortcut.index(forDigit: digit, tabCount: window?.tabCount ?? 0) == nil || window?.selectTab == nil)
            }
            Divider()
            item("Keys", window?.showKeys).keyboardShortcut("k", modifiers: [.command, .option])
            item("Snippets", window?.showSnippets).keyboardShortcut("s", modifiers: [.command, .option])
        }
    }

    // MARK: Tilde (app) menu

    @CommandsBuilder private var appMenu: some Commands {
        CommandGroup(after: .appSettings) {
            item("Lock Now", window?.lockNow).keyboardShortcut("l", modifiers: [.command, .control])
        }
    }

    // MARK: Helpers

    /// A button that is disabled when `action` is `nil`.
    private func item(_ title: LocalizedStringKey, _ action: CommandAction?) -> some View {
        Button(title) { action?() }
            .disabled(action == nil)
    }

    private func closeTab() {
        if let close = window?.closeTab {
            close()
        } else {
            closeKeyWindow()
        }
    }

    private func closeWindow() {
        closeKeyWindow()
    }

    private func closeKeyWindow() {
        #if os(macOS)
        NSApp.keyWindow?.performClose(nil)
        #endif
    }

    private func toggleSidebar() {
        if let toggle = window?.toggleSidebar {
            toggle()
        } else {
            #if os(macOS)
            NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            #endif
        }
    }

    private func selectTab(digit: Int) {
        guard let window, let index = TabShortcut.index(forDigit: digit, tabCount: window.tabCount) else { return }
        window.selectTab?(index)
    }
}
