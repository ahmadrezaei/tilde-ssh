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

    var body: some Scene {
        WindowGroup {
            AppLockGate(lock: environment.appLock) {
                RootView()
            }
            .environment(\.tildeServices, environment.services)
            .modelContainer(environment.modelContainer)
            .preferredColorScheme(.dark)   // dark by default; Settings > Appearance will override.
            .onOpenURL { _ in /* ssh://user@host:port and tilde:// links; wired by WS5/WS6. */ }
        }
        .commands { MacCommands() }

        #if os(macOS)
        Settings {
            SettingsRoot()
                .environment(\.tildeServices, environment.services)
                .modelContainer(environment.modelContainer)
                .frame(minWidth: 480, minHeight: 360)
        }
        #endif
    }
}
