import SwiftUI
import TildeDesign
import TildeTerminal

/// Settings > Terminal: scrollback, multi-line paste confirmation, OSC 52 clipboard access, copy on select, mouse
/// reporting. Embed it inside a `Section` (it contributes rows).
public struct TerminalBehaviorSettingsSection: View {
    @Bindable private var settings: TerminalSettings

    public init(settings: TerminalSettings = .shared) {
        self.settings = settings
    }

    private static let scrollbackSteps = [1_000, 5_000, 10_000, 25_000, 50_000, TerminalBehavior.maximumScrollback]

    public var body: some View {
        Picker("Scrollback lines", selection: $settings.scrollbackLines) {
            ForEach(Self.scrollbackSteps, id: \.self) { Text($0.formatted()).tag($0) }
            if !Self.scrollbackSteps.contains(settings.scrollbackLines) {
                Text(settings.scrollbackLines.formatted()).tag(settings.scrollbackLines)
            }
        }
        Picker("Confirm multi-line paste", selection: $settings.pasteConfirmation) {
            ForEach(PasteConfirmationMode.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("Remote clipboard access (OSC 52)", selection: $settings.osc52) {
            ForEach(OSC52Policy.allCases) { Text($0.displayName).tag($0) }
        }
        Toggle("Copy on select", isOn: $settings.copyOnSelect)
        Toggle("Mouse reporting", isOn: $settings.mouseReporting)
    }
}

#Preview("Terminal") {
    NavigationStack {
        List {
            Section { TerminalBehaviorSettingsSection(settings: TerminalSettings(defaults: UserDefaults(suiteName: "preview.terminal") ?? .standard)) }
        }
    }
}
