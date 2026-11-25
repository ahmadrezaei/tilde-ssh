import SwiftData
import SwiftUI
import TildeDesign
import TildeStore
import TildeTerminal

/// Settings root: Appearance, Keyboard, Terminal, Connections, Security, Sync, Data, About (design section 4.7).
///
/// Each sub-section is its own view. Security is `SecuritySettingsSection` (WS3). Appearance and Keyboard are owned by
/// WS4: the `AppearanceSettings` and `KeyboardSettings` views below are interim shells to be replaced by WS4's
/// section views when they land (the key bar editor link uses WS4's `KeyBarEditorView` already).
public struct SettingsRoot: View {
    @Environment(\.dismiss) private var dismiss
    private let showsDone: Bool

    /// - Parameter showsDone: show a Done button (when presented as a sheet).
    public init(showsDone: Bool = false) { self.showsDone = showsDone }

    public var body: some View {
        NavigationStack {
            Form {
                Section { AppearanceSettings() } header: { Text("Appearance").tildeSectionHeader() }
                Section { KeyboardSettings() } header: { Text("Keyboard").tildeSectionHeader() }
                Section { TerminalSettingsSection() } header: { Text("Terminal").tildeSectionHeader() }
                Section { ConnectionSettingsSection() } header: { Text("Connections").tildeSectionHeader() }
                Section { SecuritySettingsSection() } header: { Text("Security").tildeSectionHeader() }
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

/// Interim Appearance section: the app appearance switch the shell needs (it applies `preferredColorScheme`).
/// WS4 replaces this with theme, font, size, cursor and bell.
struct AppearanceSettings: View {
    @AppStorage(TildeSettings.appearanceKey) private var appearance = AppAppearance.dark.rawValue

    var body: some View {
        Picker("App appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
        }
    }
}

/// Interim Keyboard section: the key bar editor link. WS4 replaces this with haptics, Option as Meta, and so on.
struct KeyboardSettings: View {
    var body: some View {
        NavigationLink("Key bar") { KeyBarEditorView() }
    }
}

#Preview("Settings") {
    TildePreviewHost(openSession: false) { _ in SettingsRoot() }
}
