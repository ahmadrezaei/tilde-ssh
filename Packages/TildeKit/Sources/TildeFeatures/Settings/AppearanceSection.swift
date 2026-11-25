import SwiftUI
import TildeDesign
import TildeTerminal

/// Settings > Appearance: theme, app appearance (stored under `TildeSettings.appearanceKey`), font, font size, cursor, bell. Embed it inside a `Section`
/// (it contributes rows). Reads and writes `TerminalSettings` (pass your own instance, or use the shared one).
public struct AppearanceSettingsSection: View {
    @Bindable private var settings: TerminalSettings
    /// The app shell reads this key to apply `preferredColorScheme`.
    @AppStorage(TildeSettings.appearanceKey) private var appAppearance = AppAppearance.dark.rawValue

    public init(settings: TerminalSettings = .shared) {
        self.settings = settings
    }

    public var body: some View {
        Picker("Theme", selection: $settings.themeID) {
            ForEach(TerminalTheme.builtIn) { theme in
                Label { Text(theme.name) } icon: { ThemeSwatch(theme: theme) }.tag(theme.id)
            }
        }
        ThemePreview(theme: settings.theme, font: settings.font, size: settings.fontSize)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        Picker("App appearance", selection: $appAppearance) {
            ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Picker("Font", selection: $settings.font) {
            // Only typefaces this device can draw. A saved choice that is gone stays listed so the picker shows it.
            ForEach(TerminalFontChoice.allCases.filter { $0.isAvailable || $0 == settings.font }) { choice in
                Text(choice.isAvailable ? choice.displayName : "\(choice.displayName) (not installed)").tag(choice)
            }
        }
        Stepper(value: $settings.fontSize, in: TerminalAppearance.minimumFontSize...TerminalAppearance.maximumFontSize, step: 1) {
            HStack {
                Text("Font size")
                Spacer()
                Text("\(Int(settings.fontSize)) pt").font(TildeFont.mono(14)).foregroundStyle(TildeColor.text2)
            }
        }
        Picker("Cursor", selection: $settings.cursorShape) {
            ForEach(TerminalCursorShape.allCases) { Text($0.displayName).tag($0) }
        }
        Toggle("Blinking cursor", isOn: $settings.cursorBlink)
        Picker("Bell", selection: $settings.bell) {
            ForEach(TerminalBellMode.allCases) { Text($0.displayName).tag($0) }
        }
    }
}

private struct ThemeSwatch: View {
    let theme: TerminalTheme

    var body: some View {
        HStack(spacing: 0) {
            Color(hex: theme.background)
            Color(hex: theme.ansi[2])
            Color(hex: theme.ansi[4])
            Color(hex: theme.ansi[1])
        }
        .frame(width: 36, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(TildeColor.border, lineWidth: 0.5))
    }
}

/// A few coloured lines in the chosen theme and font.
private struct ThemePreview: View {
    let theme: TerminalTheme
    let font: TerminalFontChoice
    let size: Double

    var body: some View {
        let pt = min(size, 14)
        let mono: Font = switch font {
        case .sfMono: .system(size: pt, design: .monospaced)
        case .menlo: .custom("Menlo-Regular", size: pt)
        case .jetBrainsMonoNF: font.isAvailable ? .custom("JetBrainsMonoNFM-Regular", size: pt) : .system(size: pt, design: .monospaced)
        }
        let fg = Color(hex: theme.foreground)
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Text("deploy@db-primary").foregroundColor(Color(hex: theme.ansi[2]))):\(Text("~").foregroundColor(Color(hex: theme.ansi[4])))$ ls")
                .foregroundColor(fg)
            Text("\(Text("backups  ").foregroundColor(Color(hex: theme.ansi[4])))\(Text("deploy.sh  ").foregroundColor(Color(hex: theme.ansi[2])))\(Text("archive.tar.gz").foregroundColor(Color(hex: theme.ansi[1])))")
            Text("\(Text("warning: ").foregroundColor(Color(hex: theme.ansi[3])))disk 91% full")
                .foregroundColor(fg)
        }
        .font(mono)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: theme.background), in: RoundedRectangle(cornerRadius: TildeRadius.key))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Theme preview, \(theme.name)")
    }
}

#Preview("Appearance") {
    NavigationStack {
        List {
            Section { AppearanceSettingsSection(settings: TerminalSettings(defaults: UserDefaults(suiteName: "preview.appearance") ?? .standard)) }
        }
    }
}
