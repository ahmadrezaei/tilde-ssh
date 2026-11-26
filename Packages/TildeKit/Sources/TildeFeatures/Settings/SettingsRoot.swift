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
        if showsDone { sheetBody } else { MacSettingsTabs() }
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

/// The panes of the Mac Settings window, in tab order. The Mac window is a `TabView` with toolbar-style tabs; every
/// pane is a grouped `Form` over the same section views iPad and iPhone use, at a fixed size so the window never
/// jumps to an odd shape between tabs.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, terminal, security, sync, knownHosts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .terminal: "Terminal"
        case .security: "Security"
        case .sync: "Sync"
        case .knownHosts: "Known Hosts"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .terminal: "terminal"
        case .security: "lock.shield"
        case .sync: "icloud"
        case .knownHosts: "checkmark.shield"
        }
    }

    /// The pane's fixed content size. The Form scrolls inside it when a pane has more rows than fit.
    var size: CGSize {
        switch self {
        case .general: CGSize(width: 560, height: 520)
        case .terminal: CGSize(width: 580, height: 620)
        case .security: CGSize(width: 560, height: 440)
        case .sync: CGSize(width: 540, height: 400)
        case .knownHosts: CGSize(width: 760, height: 480)
        }
    }
}

#if os(macOS)
/// The Mac Settings window: General, Terminal, Security, Sync and Known Hosts.
private struct MacSettingsTabs: View {
    var body: some View {
        TabView {
            ForEach(SettingsPane.allCases) { pane in
                Tab(LocalizedStringKey(pane.title), systemImage: pane.symbol) {
                    content(for: pane)
                        .frame(width: pane.size.width, height: pane.size.height)
                }
            }
        }
        .background(TildeColor.bg)
    }

    @ViewBuilder
    private func content(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: form { generalSections }
        case .terminal: form { terminalSections }
        case .security: form { Section { SecuritySettingsSection() } header: { Text("Security").tildeSectionHeader() } }
        case .sync: form { SyncSettingsSection() }
        case .knownHosts: KnownHostsTable()
        }
    }

    /// A grouped form in its own stack: Acknowledgements and the key bar editor push a page.
    private func form(@ViewBuilder _ sections: () -> some View) -> some View {
        NavigationStack {
            Form { sections() }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(TildeColor.bg)
        }
    }

    @ViewBuilder private var generalSections: some View {
        Section { AppAppearanceRow() } header: { Text("Appearance").tildeSectionHeader() }
        Section { ConnectionSettingsSection() } header: { Text("Connections").tildeSectionHeader() }
        DataSettingsSection()
        AboutSettingsSection()
    }

    @ViewBuilder private var terminalSections: some View {
        Section { AppearanceSettingsSection(includesAppAppearance: false) } header: { Text("Appearance").tildeSectionHeader() }
        Section { KeyboardSettingsSection() } header: { Text("Keyboard").tildeSectionHeader() }
        Section {
            TerminalBehaviorSettingsSection()
            TerminalSettingsSection()
        } header: { Text("Terminal").tildeSectionHeader() }
    }
}
#endif

#Preview("Settings") {
    TildePreviewHost(openSession: false) { _ in SettingsRoot() }
}
