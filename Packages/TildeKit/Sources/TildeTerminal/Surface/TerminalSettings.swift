import Foundation
import Observation
import TildeCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Value types

/// Terminal typeface (docs/DESIGN.md section 2.3).
public enum TerminalFontChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case sfMono, jetBrainsMonoNF, menlo

    public var id: String { rawValue }

    /// Whether the typeface can be used on this device. JetBrains Mono NF needs its font file bundled
    /// (`App/Resources/Fonts`); until it is, choosing it falls back to SF Mono.
    public var isAvailable: Bool {
        switch self {
        case .sfMono, .menlo: true
        case .jetBrainsMonoNF: TerminalFonts.isJetBrainsAvailable
        }
    }

    public var displayName: String {
        switch self {
        case .sfMono: "SF Mono"
        case .jetBrainsMonoNF: "JetBrains Mono NF"
        case .menlo: "Menlo"
        }
    }
}

public enum TerminalCursorShape: String, Codable, CaseIterable, Sendable, Identifiable {
    case block, bar, underline
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

/// How the BEL character is signalled.
public enum TerminalBellMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case haptic, visual, off
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .haptic: "Haptic"
        case .visual: "Visual flash"
        case .off: "Off"
        }
    }
}

/// When pasting text that contains a newline asks for confirmation (docs/DESIGN.md section 4.5).
public enum PasteConfirmationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case prodOnly, always, never
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .prodOnly: "Prod only"
        case .always: "Always"
        case .never: "Never"
        }
    }

    /// Whether a multi-line paste into a server with this environment needs confirmation.
    public func requiresConfirmation(for environment: ServerEnvironment) -> Bool {
        switch self {
        case .prodOnly: environment == .prod
        case .always: true
        case .never: false
        }
    }
}

/// What a program in the terminal may do to the clipboard through OSC 52. Off by default: a remote host
/// should not be able to read or write the clipboard unless the user opted in.
public enum OSC52Policy: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, writeOnly, readWrite
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .off: "Off"
        case .writeOnly: "Allow copy"
        case .readWrite: "Allow copy and paste"
        }
    }
}

/// The app-wide light/dark choice (Settings > Appearance). The app shell applies it with `preferredColorScheme`.
public enum AppAppearance: String, Codable, CaseIterable, Sendable, Identifiable {
    case dark, system, light
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .dark: "Dark"
        case .system: "Match System"
        case .light: "Light"
        }
    }
}

/// Look of the terminal, apart from colours (those come from `TerminalTheme`).
public struct TerminalAppearance: Equatable, Sendable {
    /// Smallest size the terminal font may take (docs/DESIGN.md section 2.3).
    public static let minimumFontSize: Double = 9
    public static let maximumFontSize: Double = 32

    public var font: TerminalFontChoice
    public var fontSize: Double
    public var cursorShape: TerminalCursorShape
    public var cursorBlink: Bool
    public var bell: TerminalBellMode

    public init(
        font: TerminalFontChoice = .sfMono,
        fontSize: Double = 13,
        cursorShape: TerminalCursorShape = .block,
        cursorBlink: Bool = false,
        bell: TerminalBellMode = .haptic
    ) {
        self.font = font
        self.fontSize = Self.clamp(fontSize)
        self.cursorShape = cursorShape
        self.cursorBlink = cursorBlink
        self.bell = bell
    }

    /// 12 pt on iPhone, 13 pt on iPad and Mac.
    @MainActor public static var platformDefaultFontSize: Double {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone ? 12 : 13
        #else
        13
        #endif
    }

    public static func clamp(_ size: Double) -> Double { min(max(size, minimumFontSize), maximumFontSize) }
}

/// Terminal behaviour that is not about looks.
public struct TerminalBehavior: Equatable, Sendable {
    public var scrollbackLines: Int
    public var pasteConfirmation: PasteConfirmationMode
    public var osc52: OSC52Policy
    /// Copy the selection to the clipboard as soon as it is made (Mac setting).
    public var copyOnSelect: Bool
    /// Forward mouse events to programs that ask for them (vim, htop, tmux).
    public var mouseReporting: Bool

    public static let defaultScrollback = 10_000
    public static let maximumScrollback = 100_000

    public init(
        scrollbackLines: Int = TerminalBehavior.defaultScrollback,
        pasteConfirmation: PasteConfirmationMode = .prodOnly,
        osc52: OSC52Policy = .off,
        copyOnSelect: Bool = false,
        mouseReporting: Bool = true
    ) {
        self.scrollbackLines = min(max(scrollbackLines, 0), Self.maximumScrollback)
        self.pasteConfirmation = pasteConfirmation
        self.osc52 = osc52
        self.copyOnSelect = copyOnSelect
        self.mouseReporting = mouseReporting
    }

    public static let `default` = TerminalBehavior()
}

/// A multi-line paste waiting for the user's confirmation.
public struct PasteRequest: Sendable, Equatable {
    public let text: String
    public let environment: ServerEnvironment
    /// Number of lines in `text` (a trailing newline does not add a line).
    public let lineCount: Int
    /// The first five lines, for the confirmation sheet.
    public let preview: [String]

    public init(text: String, environment: ServerEnvironment) {
        self.text = text
        self.environment = environment
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        var counted = lines.count
        if let last = lines.last, last.isEmpty, counted > 1 { counted -= 1 }
        self.lineCount = counted
        self.preview = lines.prefix(5).map(String.init)
    }

    /// Whether the text contains a line break (the trigger for the paste guard).
    public static func isMultiLine(_ text: String) -> Bool {
        text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
    }
}

// MARK: - Observable store

/// User-facing terminal preferences (Settings > Appearance, Keyboard, Terminal), persisted in `UserDefaults`.
///
/// Font size is stored per device on purpose (screens differ), so it never goes through sync. Everything else
/// can be moved to another store by the app shell: the key bar layout goes through `KeyBarLayoutStoring`,
/// and `TerminalSettings` takes the `UserDefaults` to use.
@MainActor
@Observable
public final class TerminalSettings {
    /// A shared instance on `UserDefaults.standard`. The app shell may create its own instead.
    public static let shared = TerminalSettings()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let layoutStore: any KeyBarLayoutStoring

    public var themeID: String { didSet { save(themeID, "theme") } }
    public var appAppearance: AppAppearance { didSet { save(appAppearance.rawValue, "appAppearance") } }
    public var font: TerminalFontChoice { didSet { save(font.rawValue, "font") } }
    public var fontSize: Double { didSet { defaults.set(fontSize, forKey: key("fontSize")) } }
    public var cursorShape: TerminalCursorShape { didSet { save(cursorShape.rawValue, "cursorShape") } }
    public var cursorBlink: Bool { didSet { defaults.set(cursorBlink, forKey: key("cursorBlink")) } }
    public var bell: TerminalBellMode { didSet { save(bell.rawValue, "bell") } }

    public var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: key("haptics")) } }
    public var optionAsMeta: Bool { didSet { defaults.set(optionAsMeta, forKey: key("optionAsMeta")) } }
    public var commandPeriodSendsEscape: Bool { didSet { defaults.set(commandPeriodSendsEscape, forKey: key("cmdPeriod")) } }
    public var hardwareKeyboardMode: HardwareKeyboardMode { didSet { save(hardwareKeyboardMode.rawValue, "hwKeyboard") } }

    public var scrollbackLines: Int { didSet { defaults.set(scrollbackLines, forKey: key("scrollback")) } }
    public var pasteConfirmation: PasteConfirmationMode { didSet { save(pasteConfirmation.rawValue, "pasteConfirm") } }
    public var osc52: OSC52Policy { didSet { save(osc52.rawValue, "osc52") } }
    public var copyOnSelect: Bool { didSet { defaults.set(copyOnSelect, forKey: key("copyOnSelect")) } }
    public var mouseReporting: Bool { didSet { defaults.set(mouseReporting, forKey: key("mouse")) } }

    public var keyBarLayout: KeyBarLayout { didSet { layoutStore.save(keyBarLayout) } }

    public init(defaults: UserDefaults = .standard, layoutStore: (any KeyBarLayoutStoring)? = nil) {
        self.defaults = defaults
        let store = layoutStore ?? UserDefaultsKeyBarLayoutStore.current(defaults: defaults)
        self.layoutStore = store

        func string<T: RawRepresentable>(_ name: String, _ fallback: T) -> T where T.RawValue == String {
            if let raw = defaults.string(forKey: "tilde.terminal.\(name)"), let value = T(rawValue: raw) { return value }
            return fallback
        }
        func bool(_ name: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: "tilde.terminal.\(name)") as? Bool ?? fallback
        }

        themeID = defaults.string(forKey: "tilde.terminal.theme") ?? TerminalTheme.tildeNight.id
        appAppearance = string("appAppearance", .dark)
        font = string("font", .sfMono)
        let storedSize = defaults.double(forKey: "tilde.terminal.fontSize")
        fontSize = storedSize > 0 ? TerminalAppearance.clamp(storedSize) : TerminalAppearance.platformDefaultFontSize
        cursorShape = string("cursorShape", .block)
        cursorBlink = bool("cursorBlink", false)
        bell = string("bell", .haptic)
        hapticsEnabled = bool("haptics", true)
        optionAsMeta = bool("optionAsMeta", true)
        commandPeriodSendsEscape = bool("cmdPeriod", true)
        hardwareKeyboardMode = string("hwKeyboard", .slimStrip)
        let storedScrollback = defaults.object(forKey: "tilde.terminal.scrollback") as? Int
        scrollbackLines = storedScrollback ?? TerminalBehavior.defaultScrollback
        pasteConfirmation = string("pasteConfirm", .prodOnly)
        osc52 = string("osc52", .off)
        copyOnSelect = bool("copyOnSelect", false)
        mouseReporting = bool("mouse", true)
        keyBarLayout = store.load() ?? .devOps
    }

    // MARK: Derived values for `TerminalSurface`

    public var theme: TerminalTheme { TerminalTheme.theme(withID: themeID) }

    public var appearance: TerminalAppearance {
        TerminalAppearance(font: font, fontSize: fontSize, cursorShape: cursorShape, cursorBlink: cursorBlink, bell: bell)
    }

    public var behavior: TerminalBehavior {
        TerminalBehavior(scrollbackLines: scrollbackLines, pasteConfirmation: pasteConfirmation, osc52: osc52,
                         copyOnSelect: copyOnSelect, mouseReporting: mouseReporting)
    }

    public var keyBarConfiguration: KeyBarConfiguration {
        KeyBarConfiguration(layout: keyBarLayout, hapticsEnabled: hapticsEnabled, hardwareKeyboardMode: hardwareKeyboardMode,
                            optionAsMeta: optionAsMeta, commandPeriodSendsEscape: commandPeriodSendsEscape)
    }

    /// Records a font size change (pinch, Cmd +/-).
    public func setFontSize(_ size: Double) { fontSize = TerminalAppearance.clamp(size) }

    // MARK: Persistence

    private func key(_ name: String) -> String { "tilde.terminal.\(name)" }
    private func save(_ value: String, _ name: String) { defaults.set(value, forKey: key(name)) }
}
