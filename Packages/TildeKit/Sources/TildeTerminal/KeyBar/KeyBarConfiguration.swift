import Foundation

/// How the key bar behaves when a hardware keyboard is attached (Settings > Keyboard).
public enum HardwareKeyboardMode: String, Codable, Sendable, CaseIterable {
    case slimStrip, hidden
}

/// Versioned, syncable key bar layout (`KeyBarLayout v1`, stored in `NSUbiquitousKeyValueStore`).
/// Placeholder shape: WS4 owns the real definition (pages, 6 slots, flick alternates, pinned zone, presets).
public struct KeyBarLayout: Codable, Hashable, Sendable {
    public var version: Int
    public var presetName: String

    public init(version: Int = 1, presetName: String = "DevOps") {
        self.version = version
        self.presetName = presetName
    }

    public static let devOps = KeyBarLayout()
}

/// Everything `TerminalSurface` needs to build the key bar.
public struct KeyBarConfiguration: Sendable {
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
