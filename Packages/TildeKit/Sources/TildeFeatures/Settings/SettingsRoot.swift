import SwiftUI
import TildeDesign

/// Settings root: Appearance, Keyboard, Terminal, Connections, Security, Sync, Data, About.
/// Placeholder (WS5): composes the sections owned by WS3 and WS4 once they exist.
public struct SettingsRoot: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section { SecuritySettingsSection() } header: { Text("Security").tildeSectionHeader() }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview { SettingsRoot() }
