import SwiftData
import SwiftUI
import TildeCore
import TildeFeatures
import TildeSecurity

@main
struct TildeApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @State private var environment = AppEnvironment.mock()
    @AppStorage(TildeSettings.appearanceKey) private var appearance = AppAppearance.dark.rawValue

    private var colorScheme: ColorScheme? { AppAppearance.from(rawValue: appearance).colorScheme }

    var body: some Scene {
        // Main window: iPhone tab bar, or iPad/Mac split view. `ssh://` links are handled inside `WindowHost`.
        WindowGroup {
            AppLockGate(lock: environment.appLock) {
                RootView()
            }
            .tildeEnvironment(environment)
            .preferredColorScheme(colorScheme)   // dark by default; Settings > Appearance overrides.
        }
        // Keyboard shortcuts (Cmd-T, Cmd-W, Cmd-1...9, Cmd-P, ...). WS6's `MacCommands` adds the Mac-only menu items.
        .commands { SessionCommands() }

        // "Open in New Window" on a tab: one tab, one window (iPadOS Stage Manager and Mac).
        WindowGroup("Session", id: "session", for: UUID.self) { $tabID in
            AppLockGate(lock: environment.appLock) {
                DetachedSessionWindow(tabID: tabID)
            }
            .tildeEnvironment(environment)
            .preferredColorScheme(colorScheme)
        }

        #if os(macOS)
        Settings {
            SettingsRoot()
                .tildeEnvironment(environment)
                .preferredColorScheme(colorScheme)
                .frame(minWidth: 520, minHeight: 420)
        }
        #endif
    }
}

private extension View {
    /// Everything feature views read from the environment: services, the session coordinator and the store.
    @MainActor
    func tildeEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environment(\.tildeServices, environment.services)
            .environment(environment.coordinator)
            .modelContainer(environment.modelContainer)
    }
}
