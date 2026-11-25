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

    init(coordinator: SessionCoordinator, windowID: UUID) {
        self.coordinator = coordinator
        self.windowID = windowID
    }

    public var selectedTab: SessionTab? { coordinator.selectedTab(in: windowID) }
    public var tabs: [SessionTab] { coordinator.tabs(in: windowID) }

    public func present(_ sheet: AppSheet) { self.sheet = sheet }

    public func focusSearch() {
        phoneTab = .servers
        focusSearchToken += 1
    }

    /// Opens (or focuses) a session. In the compact layout this also brings up the session deck.
    @discardableResult
    public func open(_ server: ServerSnapshot, newSession: Bool = false, adHoc: Bool = false) -> SessionTab {
        let tab = coordinator.open(server, in: windowID, newSession: newSession, adHoc: adHoc)
        showDeckIfCompact()
        return tab
    }

    /// Brings up the deck (compact layout only).
    public func showDeckIfCompact() {
        if isCompact { isDeckPresented = true }
    }

    /// "Save as server…" for a Quick Connect tab.
    public func saveAsServer(_ tab: SessionTab) {
        coordinator.saveServerRequest = SaveServerRequest(server: tab.server, password: nil)
    }

    public func reopenLastClosed() {
        if coordinator.reopenLastClosed(in: windowID) != nil { showDeckIfCompact() }
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
