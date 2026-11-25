import SwiftUI
import TildeDesign
import TildeTerminal

/// Settings > Keyboard: key bar editor, haptics, Option as Meta, Cmd-period sends Esc, behaviour with a hardware
/// keyboard. Embed it inside a `Section` (it contributes rows); the editor row needs a `NavigationStack` above.
public struct KeyboardSettingsSection: View {
    @Bindable private var settings: TerminalSettings

    public init(settings: TerminalSettings = .shared) {
        self.settings = settings
    }

    public var body: some View {
        NavigationLink {
            KeyBarEditorView(settings: settings)
        } label: {
            HStack {
                Text("Key bar")
                Spacer()
                Text(settings.keyBarLayout.presetName).foregroundStyle(TildeColor.text2)
            }
        }
        Toggle("Haptics", isOn: $settings.hapticsEnabled)
        Toggle("Option as Meta", isOn: $settings.optionAsMeta)
        Toggle("⌘. sends Esc", isOn: $settings.commandPeriodSendsEscape)
        Picker("With hardware keyboard", selection: $settings.hardwareKeyboardMode) {
            Text("Slim strip").tag(HardwareKeyboardMode.slimStrip)
            Text("Hide").tag(HardwareKeyboardMode.hidden)
        }
    }
}

#Preview("Keyboard") {
    NavigationStack {
        List {
            Section { KeyboardSettingsSection(settings: TerminalSettings(defaults: UserDefaults(suiteName: "preview.keyboard") ?? .standard)) }
        }
    }
}
