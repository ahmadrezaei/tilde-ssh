import Foundation

/// A terminal colour theme. Colours are `0xRRGGBB` (selection is `0xRRGGBBAA`) so the type has no UI
/// framework dependency and can be unit-tested. WS4 owns this file and may extend it (font, bold-as-bright, ...).
public struct TerminalTheme: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var background: UInt32
    public var foreground: UInt32
    public var cursor: UInt32
    public var selection: UInt32
    /// 16 ANSI colours: 0-7 normal (black, red, green, yellow, blue, magenta, cyan, white), 8-15 bright.
    public var ansi: [UInt32]

    public init(id: String, name: String, background: UInt32, foreground: UInt32, cursor: UInt32, selection: UInt32, ansi: [UInt32]) {
        precondition(ansi.count == 16, "A theme needs exactly 16 ANSI colours")
        self.id = id
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
    }

    /// The default theme (docs/DESIGN.md section 2.4).
    public static let tildeNight = TerminalTheme(
        id: "tilde-night", name: "Tilde Night",
        background: 0x0B0F14, foreground: 0xD6DEE6, cursor: 0x2DD4BF, selection: 0x2DD4BF33,
        ansi: [
            0x1C232B, 0xF7525F, 0x3FD68B, 0xF5B83D, 0x58A6FF, 0xC792EA, 0x2DD4BF, 0xC9D1D9,
            0x4B5663, 0xFF7B85, 0x6EE7A8, 0xFFD479, 0x82BFFF, 0xDDB6F2, 0x7CF5DD, 0xF5F8FA,
        ]
    )

    /// All built-in themes. WS4 adds Tilde Day and Midnight High Contrast.
    public static let builtIn: [TerminalTheme] = [.tildeNight]
}
