import SwiftUI
import TildeCore

public extension EnvironmentValues {
    /// The service contracts (secret store, key service, session engine, ...). `AppEnvironment` (WS5) injects the
    /// real implementations; every feature view reads them from here. Defaults to the mocks, so previews
    /// work without any setup.
    @Entry var tildeServices: TildeServices = .preview
}
