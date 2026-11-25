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

    /// The real services, built once at launch (the mocks only with `TILDE_MOCK_ENVIRONMENT=1`).
    @State private var launch = AppEnvironment.launch()
    @AppStorage(TildeSettings.appearanceKey) private var appearance = AppAppearance.dark.rawValue

    private var colorScheme: ColorScheme? { AppAppearance.from(rawValue: appearance).colorScheme }

    var body: some Scene {
        // Main window: iPhone tab bar, or iPad/Mac split view. `ssh://` links are handled inside `WindowHost`.
        WindowGroup {
            switch launch {
            case .success(let environment):
                LockedWindow(environment: environment) { RootView() }
                    .preferredColorScheme(colorScheme)   // dark by default; Settings > Appearance overrides.
            case .failure(let error):
                StoreFailureView(error: error)
                    .preferredColorScheme(colorScheme)
            }
        }
        // The menu bar (Mac and iPadOS 26). It reads the actions each window publishes through `WindowHost`; while the
        // app is locked a window publishes none, so every item that acts on content is disabled.
        .commands { MacCommands() }
        .defaultSize(width: 1180, height: 760)

        // "Open in New Window" on a tab: one tab, one window (iPadOS Stage Manager and Mac).
        WindowGroup("Session", id: "session", for: SessionWindowValue.self) { $value in
            if case .success(let environment) = launch {
                LockedWindow(environment: environment) { DetachedSessionWindow(tabID: value?.sessionID) }
                    .preferredColorScheme(colorScheme)
            }
        }

        #if os(macOS)
        // The Settings scene is its own window: it needs the lock gate too, or Settings (known hosts, keys, the lock
        // switch itself) would be reachable while the app is locked.
        Settings {
            if case .success(let environment) = launch {
                LockedWindow(environment: environment) { SettingsRoot() }
                    .preferredColorScheme(colorScheme)
                    .frame(minWidth: 520, minHeight: 420)
            }
        }
        #endif
    }
}

/// One window's root: the lock gate around the content, with every service the feature views read injected.
private struct LockedWindow<Content: View>: View {
    let environment: AppEnvironment
    @ViewBuilder let content: () -> Content

    var body: some View {
        AppLockGate(lock: environment.appLock) {
            content()
                .environment(\.tildeServices, environment.services)
                .environment(environment.coordinator)
                .environment(\.lockNowAction, LockNowAction { environment.appLock.lockNow() })
                .environment(\.tildeSyncMonitor, environment.syncMonitor)
                .environment(\.tildePreferences, environment.preferences)
                .modelContainer(environment.modelContainer)
        }
    }
}

/// Shown when the on-disk store cannot be opened. The app never falls back to an empty in-memory store, because
/// whatever the user added there would vanish on quit.
private struct StoreFailureView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Tilde can't open its data")
                .font(.title2.weight(.semibold))
            Text("Your servers and keys were not touched. Restart the app; if this keeps happening, free some storage space or reinstall.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(error.localizedDescription)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: 480)
    }
}
