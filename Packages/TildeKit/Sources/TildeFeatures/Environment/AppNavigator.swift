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
    case keys, snippets, settings, generateKey, importSSHConfig
    case newSnippet
    case editSnippet(UUID)

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
        case .newSnippet: "newSnippet"
        case .editSnippet(let id): "editSnippet-\(id)"
        }
    }
}

/// The tabs of the iPhone `TabView`.
public enum PhoneTab: String, Hashable, Sendable, CaseIterable {
    case servers, keys, snippets, settings
}

/// Per-window UI routing: which sheet is up, which iPhone tab is selected, and the verbs views use to open
/// sessions. One instance per window (`RootView` creates it); injected with `.environment(navigator)`.
@MainActor
@Observable
public final class AppNavigator {
    public let windowID: UUID
    public let coordinator: SessionCoordinator

    public var sheet: AppSheet?
    public var phoneTab: PhoneTab = .servers
    /// Increment to ask the server list to focus its search / Quick Connect field.
    public var focusSearchToken = 0

    public init(coordinator: SessionCoordinator, windowID: UUID = UUID()) {
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

    /// Opens (or focuses) a session. On iPhone this also brings up the session deck.
    @discardableResult
    public func open(_ server: ServerSnapshot, newSession: Bool = false, adHoc: Bool = false) -> SessionTab {
        let tab = coordinator.open(server, in: windowID, newSession: newSession, adHoc: adHoc)
        coordinator.isDeckPresented = true
        return tab
    }

    /// "Save as server…" for a Quick Connect tab.
    public func saveAsServer(_ tab: SessionTab) {
        coordinator.saveServerRequest = SaveServerRequest(server: tab.server, password: nil)
    }

    public func reopenLastClosed() {
        if coordinator.reopenLastClosed(in: windowID) != nil { coordinator.isDeckPresented = true }
    }
}
