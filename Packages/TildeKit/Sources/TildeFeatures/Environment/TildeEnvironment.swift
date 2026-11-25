import SwiftUI
import TildeCore
import TildeStore

public extension EnvironmentValues {
    /// The service contracts (secret store, key service, session engine, ...). `AppEnvironment` (WS5) injects the
    /// real implementations; every feature view reads them from here. Defaults to the mocks, so previews
    /// work without any setup.
    @Entry var tildeServices: TildeServices = .preview
}

public extension EnvironmentValues {
    /// iCloud sync state and the "Sync on/off" switch's pending change. `nil` in previews and tests.
    @Entry var tildeSyncMonitor: SyncStatusMonitor? = nil
    /// The synced preferences store (`Preferences.live()` in the app). `nil` in previews and tests.
    @Entry var tildePreferences: Preferences? = nil
}
