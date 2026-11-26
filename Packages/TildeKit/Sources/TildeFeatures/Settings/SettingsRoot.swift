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
        #if os(macOS)
        if showsDone { sheetBody } else { windowBody }
        #else
        windowBody
        #endif
    }

    /// The settings form. Shared by the Mac Settings window, the Mac sheet and iPad / iPhone.
    private var form: some View {
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
    }

    private var windowBody: some View {
        NavigationStack {
            form
                .navigationTitle("Settings")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.large)
                #endif
                .toolbar {
                    if showsDone { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                }
        }
    }

    #if os(macOS)
    /// Settings opened as a sheet (from the command palette): the shared sheet scaffold instead of a system title bar.
    private var sheetBody: some View {
        NavigationStack {
            TildeSheet("Settings", scrolls: false, idealHeight: 720) {
                form
            } actions: {
                TildeDefaultButton("Done") { dismiss() }
            }
            // The stack is only there so Key bar can push its editor; hide its empty root title bar.
        }
    }
    #endif
}

#Preview("Settings") {
    TildePreviewHost(openSession: false) { _ in SettingsRoot() }
}
