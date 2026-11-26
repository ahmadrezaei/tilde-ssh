import SwiftUI
import TildeDesign

/// The app's own utility windows on the Mac: Keys and Snippets are windows of their own (⌥⌘K, ⌥⌘S) instead of
/// sheets over the session window. The ids are what `TildeApp` gives its `Window` scenes and what `openWindow` takes.
public enum UtilityWindow: String, CaseIterable, Sendable {
    case keys
    case snippets

    /// The scene id (`Window("Keys", id: UtilityWindow.keys.id)`).
    public var id: String { "tilde.window.\(rawValue)" }

    /// The window title, which is also its Window menu item.
    public var title: String {
        switch self {
        case .keys: "Keys"
        case .snippets: "Snippets"
        }
    }
}

/// Where an `AppSheet` goes. On iPhone and iPad every sheet is a sheet. On the Mac Keys and Snippets open their own
/// windows and Settings opens the Settings window.
enum AppSheetRoute: Equatable {
    case sheet
    case window(UtilityWindow)
    case settings
}

extension AppSheet {
    /// How the Mac presents this value. Pure, so it is unit tested; the iOS code paths never ask.
    var macRoute: AppSheetRoute {
        switch self {
        case .keys: .window(.keys)
        case .snippets: .window(.snippets)
        case .settings: .settings
        case .newServer, .editServer, .saveServer, .palette, .generateKey, .importSSHConfig, .importKnownHosts,
             .newSnippet, .editSnippet, .confirmLink:
            .sheet
        }
    }
}

extension AppNavigator {
    /// Whether a sheet is actually on screen. On the Mac a value routed to a window is never shown as a sheet, so it
    /// must not suppress the window's host-key and password prompts while it waits to be handed over.
    var isShowingSheet: Bool {
        #if os(macOS)
        sheet?.macRoute == .sheet
        #else
        sheet != nil
        #endif
    }
}

#if os(macOS)

/// Turns `navigator.present(.keys / .snippets / .settings)` into the matching window, then clears the sheet value.
/// Attached by `AppSheetHost`, which also keeps these values out of its sheet binding, so no sheet ever flashes.
struct MacUtilityWindowRouter: ViewModifier {
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        // `initial: true`: a value set before this modifier was attached (a `tilde://keys` link) is handled too.
        content.onChange(of: navigator.sheet, initial: true) { _, sheet in
            guard let sheet else { return }
            switch sheet.macRoute {
            case .sheet:
                break
            case .window(let window):
                navigator.sheet = nil
                openWindow(id: window.id)
            case .settings:
                navigator.sheet = nil
                openSettings()
            }
        }
    }
}

/// The content of a Keys or Snippets window. It has a navigator of its own (so a snippet editor or any other sheet
/// opened from inside the window shows over the window) but publishes no menu actions: a session can only be opened
/// from a main window.
struct UtilityWindowHost<Content: View>: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @State private var id = UUID()
    @ViewBuilder let content: () -> Content

    var body: some View {
        UtilityWindowBody(navigator: coordinator.navigator(for: id), content: content)
            .onDisappear { coordinator.windowClosed(id) }
    }
}

private struct UtilityWindowBody<Content: View>: View {
    let navigator: AppNavigator
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .modifier(AppSheetHost(isActive: true))
            .background(TildeColor.bg)
            .tint(TildeColor.accent)
            // Outermost, so the sheet host and the content both read this window's navigator.
            .environment(navigator)
    }
}

/// The Keys window (`Window("Keys", id: UtilityWindow.keys.id)`): the key manager in its own window.
public struct KeysWindowContent: View {
    public init() {}

    public var body: some View {
        UtilityWindowHost {
            // The stack lets a key push its detail page.
            NavigationStack { KeyListView() }
        }
    }
}

/// The Snippets window (`Window("Snippets", id: UtilityWindow.snippets.id)`): the snippet manager in its own window.
/// Inserting a snippet into a session stays in Edit > Paste Snippet and the palette, which know the session.
public struct SnippetsWindowContent: View {
    public init() {}

    public var body: some View {
        UtilityWindowHost {
            NavigationStack { SnippetList() }
        }
    }
}

#endif
