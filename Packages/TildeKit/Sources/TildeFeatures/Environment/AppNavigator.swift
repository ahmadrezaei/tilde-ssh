import Foundation
import Observation
import SwiftUI
import TildeCore

/// What the command palette is searching.
public enum PaletteMode: Equatable, Sendable {
    /// Servers, sessions, snippets and actions (Cmd-P).
    case all
    /// Servers and Quick Connect only (Cmd-T, "New tab").
    case newTab
    /// Snippets only (Cmd-Shift-S).
    case snippets
}

/// A sheet presented from the window root.
public enum AppSheet: Identifiable, Equatable {
    case newServer
    case editServer(UUID)
    /// Quick Connect session being saved ("Save as server…").
    case saveServer(SaveServerRequest)
    case palette(PaletteMode)
    case keys, snippets, settings, generateKey, importSSHConfig, importKnownHosts
    case newSnippet
    case editSnippet(UUID)
    /// A `ssh://` link asked for this connection. Nothing connects until the user confirms.
    case confirmLink(QuickConnectResult)

    public var id: String {
        switch self {
        case .newServer: "newServer"
        case .editServer(let id): "editServer-\(id)"
        case .saveServer(let request): "saveServer-\(request.id)"
        case .palette: "palette"
        case .keys: "keys"
        case .snippets: "snippets"
        case .settings: "settings"
        case .generateKey: "generateKey"
        case .importSSHConfig: "importSSHConfig"
        case .importKnownHosts: "importKnownHosts"
        case .newSnippet: "newSnippet"
        case .editSnippet(let id): "editSnippet-\(id)"
        case .confirmLink(let result): "confirmLink-\(result.target.displayString)"
        }
    }
}

/// The tabs of the iPhone `TabView`.
public enum PhoneTab: String, Hashable, Sendable, CaseIterable {
    case servers, keys, snippets, settings
}

/// Per-window UI routing: which sheet is up, whether the session deck is up, which iPhone tab is selected, and
/// the verbs views use to open sessions. One instance per window, owned by the `SessionCoordinator`
/// (`coordinator.navigator(for:)`), and injected with `.environment(navigator)` by `WindowHost`.
@MainActor
@Observable
public final class AppNavigator {
    public let windowID: UUID
    public let coordinator: SessionCoordinator

    public var sheet: AppSheet?
    public var phoneTab: PhoneTab = .servers
    /// Increment to ask the server list to focus its search / Quick Connect field.
    public var focusSearchToken = 0

    /// `true` while this window shows the compact (iPhone) layout, which presents sessions in a full-screen deck.
    /// Set by the layout views; on iPad and Mac sessions show in the detail column and there is no deck.
    public var isCompact = false
    /// Whether the full-screen session deck is up in this window. Only ever `true` in the compact layout.
    public var isDeckPresented = false
    /// Which columns the iPad / Mac split view shows. "Toggle Sidebar" flips it between all and detail only.
    public var columnVisibility: NavigationSplitViewVisibility = .all {
        didSet { columnVisibilityChanged(from: oldValue) }
    }

    /// Sidebar auto-hide policy. Opening a session hides the sidebar; once the user brings it back by hand while
    /// sessions are open, it is not hidden again in this window until every tab has closed. On by default on the Mac
    /// only; iPad keeps hiding the sidebar every time a session opens.
    var remembersManualSidebarShow = Platform.isMac
    /// The user showed the sidebar by hand while at least one tab was open.
    @ObservationIgnored private(set) var sidebarShownByHand = false

    init(coordinator: SessionCoordinator, windowID: UUID) {
        self.coordinator = coordinator
        self.windowID = windowID
    }

    public var selectedTab: SessionTab? { coordinator.selectedTab(in: windowID) }
    public var tabs: [SessionTab] { coordinator.tabs(in: windowID) }

    public func present(_ sheet: AppSheet) { self.sheet = sheet }

    public func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }

    public func focusSearch() {
        phoneTab = .servers
        #if os(macOS)
        // Quick Connect lives in the sidebar's search field, so ⌘L has to bring the sidebar up. That is not the user
        // re-showing it for good: the next session still hides it.
        if !isCompact, columnVisibility == .detailOnly {
            let shownByHand = sidebarShownByHand
            columnVisibility = .all
            sidebarShownByHand = shownByHand
        }
        #endif
        focusSearchToken += 1
    }

    /// Opens (or focuses) a session. In the compact layout this also brings up the session deck.
    @discardableResult
    public func open(_ server: ServerSnapshot, newSession: Bool = false, adHoc: Bool = false) -> SessionTab {
        let wasEmpty = tabs.isEmpty
        let tab = coordinator.open(server, in: windowID, newSession: newSession, adHoc: adHoc)
        if wasEmpty { sidebarShownByHand = false }
        showSession()
        return tab
    }

    /// Brings up the deck (compact layout only).
    public func showDeckIfCompact() {
        if isCompact { isDeckPresented = true }
    }

    /// Makes room for a session that just opened: the deck on iPhone, the terminal alone (sidebar hidden) on iPad and
    /// Mac, unless the user re-showed the sidebar by hand (`remembersManualSidebarShow`). The sidebar comes back when
    /// the window's last tab closes (`SessionContainer`).
    public func showSession() {
        if isCompact {
            isDeckPresented = true
        } else if !(remembersManualSidebarShow && sidebarShownByHand) {
            #if os(macOS)
            // No slide: the sidebar's rows change in this same update (the live dot), and animating the column away
            // while its outline view re-lays those rows out is the window where SwiftUI's table can abort.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { columnVisibility = .detailOnly }
            #else
            columnVisibility = .detailOnly
            #endif
        }
    }

    /// Tracks the manual re-show. Only a change from hidden to visible while tabs are open counts, so layout echoes
    /// (`.all` written over `.all`) and the app's own writes do not. With no tabs left the memory is cleared.
    private func columnVisibilityChanged(from old: NavigationSplitViewVisibility) {
        guard remembersManualSidebarShow else { return }
        if tabs.isEmpty {
            sidebarShownByHand = false
        } else if old == .detailOnly, columnVisibility != .detailOnly {
            sidebarShownByHand = true
        }
    }

    /// "Save as server…" for a Quick Connect tab.
    public func saveAsServer(_ tab: SessionTab) {
        coordinator.saveServerRequest = SaveServerRequest(server: tab.server, password: nil)
    }

    public func reopenLastClosed() {
        let wasEmpty = tabs.isEmpty
        guard coordinator.reopenLastClosed(in: windowID) != nil else { return }
        if wasEmpty { sidebarShownByHand = false }
        showSession()
    }

    /// Handles an incoming `ssh://` or `tilde://` link. **A link never connects by itself**: a connect link raises a
    /// confirmation sheet, and only the user's "Connect" opens a session (password prompt only, see
    /// `QuickConnectResolver.linkServer`).
    public func handleLink(_ url: URL) {
        let parser = TildeURLParser(defaultUsername: TildeSettings.currentDefaultUser)
        switch parser.parse(url) {
        case .connect(let result):
            present(.confirmLink(result))
        case .newServer(let result, let name):
            let snapshot = ServerSnapshot(name: name ?? result.target.host, target: result.target, auth: .passwordPrompt)
            present(.saveServer(SaveServerRequest(server: snapshot, password: nil)))
        case .show(let destination):
            show(destination)
        case nil:
            break
        }
    }

    /// Shows a `tilde://` destination: a tab on iPhone, a sheet elsewhere.
    public func show(_ destination: TildeURLDestination) {
        switch destination {
        case .servers: phoneTab = .servers
        case .keys: if isCompact { phoneTab = .keys } else { present(.keys) }
        case .snippets: if isCompact { phoneTab = .snippets } else { present(.snippets) }
        case .settings: if isCompact { phoneTab = .settings } else { present(.settings) }
        }
    }
}
