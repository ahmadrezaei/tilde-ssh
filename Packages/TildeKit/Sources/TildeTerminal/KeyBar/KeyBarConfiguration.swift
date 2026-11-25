import Foundation

/// How the key bar behaves when a hardware keyboard is attached (Settings > Keyboard).
public enum HardwareKeyboardMode: String, Codable, Sendable, CaseIterable {
    /// A 32 pt strip with Esc, F-keys, snippets and a Ctrl lock.
    case slimStrip
    /// No key bar at all.
    case hidden
}

/// Everything `TerminalSurface` needs to build the key bar and to treat the keyboard.
public struct KeyBarConfiguration: Sendable, Equatable {
    public var layout: KeyBarLayout
    public var hapticsEnabled: Bool
    public var hardwareKeyboardMode: HardwareKeyboardMode
    /// Option acts as Meta (hardware keyboard).
    public var optionAsMeta: Bool
    /// Command-period sends Esc.
    public var commandPeriodSendsEscape: Bool

    public init(
        layout: KeyBarLayout = .devOps,
        hapticsEnabled: Bool = true,
        hardwareKeyboardMode: HardwareKeyboardMode = .slimStrip,
        optionAsMeta: Bool = true,
        commandPeriodSendsEscape: Bool = true
    ) {
        self.layout = layout
        self.hapticsEnabled = hapticsEnabled
        self.hardwareKeyboardMode = hardwareKeyboardMode
        self.optionAsMeta = optionAsMeta
        self.commandPeriodSendsEscape = commandPeriodSendsEscape
    }

    public static let `default` = KeyBarConfiguration()
}
