import SwiftData
import SwiftUI
import TildeDesign
import TildeStore
import TildeTerminal

/// Settings root: Appearance, Keyboard, Terminal, Connections, Security, Sync, Data, About (design section 4.7).
///
/// Each sub-section is its own view. Security is `SecuritySettingsSection`. Appearance, Keyboard and the terminal
/// behaviour rows (scrollback, paste confirmation, OSC 52, ...) are section views over `TerminalSettings`.
public struct SettingsRoot: View {
    @Environment(\.dismiss) private var dismiss
    private let showsDone: Bool

    /// - Parameter showsDone: show a Done button (when presented as a sheet).
    public init(showsDone: Bool = false) { self.showsDone = showsDone }

    public var body: some View {
        NavigationStack {
            Form {
                Section { AppearanceSettingsSection() } header: { Text("Appearance").tildeSectionHeader() }
                Section { KeyboardSettingsSection() } header: { Text("Keyboard").tildeSectionHeader() }
                Section {
                    TerminalBehaviorSettingsSection()
                    TerminalSettingsSection()
                } header: { Text("Terminal").tildeSectionHeader() }
                Section { ConnectionSettingsSection() } header: { Text("Connections").tildeSectionHeader() }
                Section { SecuritySettingsSection(knownHosts: { KnownHostsListView() }) } header: { Text("Security").tildeSectionHeader() }
                SyncSettingsSection()
                DataSettingsSection()
                AboutSettingsSection()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(TildeColor.bg)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }
}

#Preview("Settings") {
    TildePreviewHost(openSession: false) { _ in SettingsRoot() }
}
