import SwiftUI

// MARK: - Focused command actions
//
// `MacCommands` (the menu bar on macOS and iPadOS 26) does not know about sessions, tabs or windows.
// The scene that does (WS5's `SessionCoordinator` owner) publishes two plain value types through
// `FocusedValues`, and the menus read them:
//
//     .windowCommandActions(WindowCommandActions(newTab: { ... }, selectTab: { ... }, tabCount: tabs.count))
//     .sessionCommandActions(session.map { SessionCommandActions(reconnect: { ... }) })
//
// A `nil` closure means "not available right now" and the corresponding menu item is disabled, so
// publishers only fill in what applies (no tabs open = no `closeTab`, no live session = no `reconnect`).
// Both modifiers use `focusedSceneValue`, which keeps working while an AppKit/UIKit terminal view
// holds first-responder status (plain `focusedValue` does not cross that boundary reliably).

/// A menu action. Always run on the main actor.
public typealias CommandAction = @MainActor @Sendable () -> Void

/// One entry in View > Theme.
public struct ThemeChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    /// - Parameters:
    ///   - id: stable identifier passed back to `WindowCommandActions.selectTheme`.
    ///   - name: the menu title (for example `Tilde Night`).
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Actions that act on the window or the app rather than on one terminal session.
///
/// Publish with `windowCommandActions(_:)` from the root view of every main window.
public struct WindowCommandActions: Sendable {
    // File
    /// File > New Tab (⌘T). Opens the Quick Connect palette.
    public var newTab: CommandAction?
    /// File > Reopen Closed Tab (⇧⌘T).
    public var reopenClosedTab: CommandAction?
    /// File > Close Tab (⌘W). When `nil`, ⌘W closes the key window instead.
    public var closeTab: CommandAction?
    /// File > New Server… (⇧⌘N).
    public var newServer: CommandAction?
    /// File > Quick Connect (⌘L). Focuses the address-bar style field.
    public var quickConnect: CommandAction?
    /// File > Command Palette… (⌘P).
    public var commandPalette: CommandAction?
    /// File > Import from ~/.ssh/config…
    public var importSSHConfig: CommandAction?
    /// File > Import known_hosts…
    public var importKnownHosts: CommandAction?

    // View
    /// View > Hide/Show Sidebar (⌃⌘S).
    public var toggleSidebar: CommandAction?
    /// View > Bigger (⌘+).
    public var increaseFontSize: CommandAction?
    /// View > Smaller (⌘−).
    public var decreaseFontSize: CommandAction?
    /// View > Actual Size (⌘0).
    public var resetFontSize: CommandAction?
    /// The themes offered by View > Theme. Empty disables the submenu.
    public var themes: [ThemeChoice]
    /// The `ThemeChoice.id` that gets the checkmark.
    public var selectedThemeID: String?
    /// Called with a `ThemeChoice.id` when the user picks a theme.
    public var selectTheme: (@MainActor @Sendable (String) -> Void)?

    // Window
    /// Number of open tabs in this window. Drives which of ⌘1…⌘9 are enabled.
    public var tabCount: Int
    /// Index (zero-based) of the active tab, if any.
    public var selectedTabIndex: Int?
    /// Window > Tab n. Called with a zero-based index; ⌘9 always passes the last tab.
    public var selectTab: (@MainActor @Sendable (Int) -> Void)?
    /// Window > Previous Tab (⇧⌘[).
    public var selectPreviousTab: CommandAction?
    /// Window > Next Tab (⇧⌘]).
    public var selectNextTab: CommandAction?
    /// Window > Move Tab to New Window.
    public var moveTabToNewWindow: CommandAction?
    /// Window > Keys (⌥⌘K).
    public var showKeys: CommandAction?
    /// Window > Snippets (⌥⌘S).
    public var showSnippets: CommandAction?

    // App
    /// Tilde > Lock Now (⌃⌘L).
    public var lockNow: CommandAction?

    /// Creates a set of window actions. Every parameter defaults to "unavailable".
    public init(
        newTab: CommandAction? = nil,
        reopenClosedTab: CommandAction? = nil,
        closeTab: CommandAction? = nil,
        newServer: CommandAction? = nil,
        quickConnect: CommandAction? = nil,
        commandPalette: CommandAction? = nil,
        importSSHConfig: CommandAction? = nil,
        importKnownHosts: CommandAction? = nil,
        toggleSidebar: CommandAction? = nil,
        increaseFontSize: CommandAction? = nil,
        decreaseFontSize: CommandAction? = nil,
        resetFontSize: CommandAction? = nil,
        themes: [ThemeChoice] = [],
        selectedThemeID: String? = nil,
        selectTheme: (@MainActor @Sendable (String) -> Void)? = nil,
        tabCount: Int = 0,
        selectedTabIndex: Int? = nil,
        selectTab: (@MainActor @Sendable (Int) -> Void)? = nil,
        selectPreviousTab: CommandAction? = nil,
        selectNextTab: CommandAction? = nil,
        moveTabToNewWindow: CommandAction? = nil,
        showKeys: CommandAction? = nil,
        showSnippets: CommandAction? = nil,
        lockNow: CommandAction? = nil
    ) {
        self.newTab = newTab
        self.reopenClosedTab = reopenClosedTab
        self.closeTab = closeTab
        self.newServer = newServer
        self.quickConnect = quickConnect
        self.commandPalette = commandPalette
        self.importSSHConfig = importSSHConfig
        self.importKnownHosts = importKnownHosts
        self.toggleSidebar = toggleSidebar
        self.increaseFontSize = increaseFontSize
        self.decreaseFontSize = decreaseFontSize
        self.resetFontSize = resetFontSize
        self.themes = themes
        self.selectedThemeID = selectedThemeID
        self.selectTheme = selectTheme
        self.tabCount = tabCount
        self.selectedTabIndex = selectedTabIndex
        self.selectTab = selectTab
        self.selectPreviousTab = selectPreviousTab
        self.selectNextTab = selectNextTab
        self.moveTabToNewWindow = moveTabToNewWindow
        self.showKeys = showKeys
        self.showSnippets = showSnippets
        self.lockNow = lockNow
    }
}

/// Actions that act on the active terminal session (the Session menu and the terminal-related Edit items).
///
/// Publish with `sessionCommandActions(_:)`; publish `nil` when no session is focused.
public struct SessionCommandActions: Sendable {
    /// Session > Reconnect (⌘R).
    public var reconnect: CommandAction?
    /// Session > Disconnect (⌥⌘W).
    public var disconnect: CommandAction?
    /// Session > Clear Scrollback (⌘K).
    public var clearScrollback: CommandAction?
    /// Session > Send Ctrl-C. Writes `0x03` to the PTY.
    public var sendInterrupt: CommandAction?
    /// Session > Send Break. Sends an SSH `break` request.
    public var sendBreak: CommandAction?
    /// Session > Edit Server…
    public var editServer: CommandAction?
    /// Session > Copy SSH Command (⌥⌘C), e.g. `ssh -p 2222 -J bastion deploy@10.0.4.12`.
    public var copySSHCommand: CommandAction?
    /// Edit > Paste Snippet… (⇧⌘S).
    public var pasteSnippet: CommandAction?
    /// Edit > Find… (⌘F). Shows the find bar over the terminal.
    public var find: CommandAction?
    /// Edit > Find Next (⌘G).
    public var findNext: CommandAction?
    /// Edit > Find Previous (⇧⌘G).
    public var findPrevious: CommandAction?

    /// Creates a set of session actions. Every parameter defaults to "unavailable".
    public init(
        reconnect: CommandAction? = nil,
        disconnect: CommandAction? = nil,
        clearScrollback: CommandAction? = nil,
        sendInterrupt: CommandAction? = nil,
        sendBreak: CommandAction? = nil,
        editServer: CommandAction? = nil,
        copySSHCommand: CommandAction? = nil,
        pasteSnippet: CommandAction? = nil,
        find: CommandAction? = nil,
        findNext: CommandAction? = nil,
        findPrevious: CommandAction? = nil
    ) {
        self.reconnect = reconnect
        self.disconnect = disconnect
        self.clearScrollback = clearScrollback
        self.sendInterrupt = sendInterrupt
        self.sendBreak = sendBreak
        self.editServer = editServer
        self.copySSHCommand = copySSHCommand
        self.pasteSnippet = pasteSnippet
        self.find = find
        self.findNext = findNext
        self.findPrevious = findPrevious
    }
}

public extension FocusedValues {
    /// Window-level menu actions. Read by `MacCommands`; published with `.windowCommandActions(_:)`.
    @Entry var windowCommands: WindowCommandActions?
    /// Session-level menu actions. Read by `MacCommands`; published with `.sessionCommandActions(_:)`.
    @Entry var sessionCommands: SessionCommandActions?
}

public extension View {
    /// Publishes `actions` to the menu bar while this scene is key. Apply once, near the root of each main window.
    func windowCommandActions(_ actions: WindowCommandActions) -> some View {
        focusedSceneValue(\.windowCommands, actions)
    }

    /// Publishes the focused session's actions to the menu bar, or removes them when `actions` is `nil`.
    func sessionCommandActions(_ actions: SessionCommandActions?) -> some View {
        focusedSceneValue(\.sessionCommands, actions)
    }
}

/// Pure helpers behind the ⌘1…⌘9 menu items, kept separate so they can be unit tested.
public enum TabShortcut {
    /// Maps the digit of a ⌘1…⌘9 shortcut to a zero-based tab index. ⌘9 selects the last tab, as in Safari and
    /// Terminal. Returns `nil` when the digit does not address an existing tab.
    public static func index(forDigit digit: Int, tabCount: Int) -> Int? {
        guard (1...9).contains(digit), tabCount > 0 else { return nil }
        if digit == 9 { return tabCount - 1 }
        return digit <= tabCount ? digit - 1 : nil
    }

    /// The tab index that follows (or precedes) `current`, wrapping around. `nil` if there are no tabs.
    public static func neighbour(of current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return forward ? 0 : count - 1 }
        return ((current + (forward ? 1 : -1)) % count + count) % count
    }
}
