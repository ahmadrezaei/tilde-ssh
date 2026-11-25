import Foundation

/// A terminal colour theme. Colours are `0xRRGGBB` (selection is `0xRRGGBBAA`) so the type has no UI
/// framework dependency and can be unit-tested.
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

    /// `true` when the background is dark (decides the keyboard appearance and scroll indicator style).
    public var isDark: Bool { Self.luminance(background) < 0.4 }

    /// WCAG contrast ratio (1...21) between two `0xRRGGBB` colours.
    public static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Relative luminance (WCAG 2.x) of a `0xRRGGBB` colour.
    public static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
    }

    // MARK: Built-in themes

    /// The default theme (docs/DESIGN.md section 2.4).
    public static let tildeNight = TerminalTheme(
        id: "tilde-night", name: "Tilde Night",
        background: 0x0B0F14, foreground: 0xD6DEE6, cursor: 0x2DD4BF, selection: 0x2DD4BF33,
        ansi: [
            0x1C232B, 0xF7525F, 0x3FD68B, 0xF5B83D, 0x58A6FF, 0xC792EA, 0x2DD4BF, 0xC9D1D9,
            0x4B5663, 0xFF7B85, 0x6EE7A8, 0xFFD479, 0x82BFFF, 0xDDB6F2, 0x7CF5DD, 0xF5F8FA,
        ]
    )

    /// Light theme on the `bg` token of the light palette. Every foreground slot keeps at least 4.5:1 against the background.
    public static let tildeDay = TerminalTheme(
        id: "tilde-day", name: "Tilde Day",
        background: 0xF6F8FA, foreground: 0x1F2328, cursor: 0x0F9F8F, selection: 0x0F9F8F33,
        ansi: [
            0x24292F, 0xCF222E, 0x1A7F37, 0x8A5A00, 0x0969DA, 0x8250DF, 0x0E7C86, 0x57606A,
            0x57606A, 0xA40E26, 0x116329, 0x6B4700, 0x0550AE, 0x6639BA, 0x0A5F67, 0x3D444D,
        ]
    )

    /// WCAG AAA (7:1) for every foreground slot except ANSI black, for incident-room projectors.
    public static let midnightHighContrast = TerminalTheme(
        id: "midnight-hc", name: "Midnight High Contrast",
        background: 0x000000, foreground: 0xFFFFFF, cursor: 0xFFFF66, selection: 0xFFFFFF55,
        ansi: [
            0x2B2B2B, 0xFF7B7B, 0x5CFF8F, 0xFFE45C, 0x7AB8FF, 0xFF8CFF, 0x5CF2FF, 0xE6E6E6,
            0x9E9E9E, 0xFFA0A0, 0x8CFFB0, 0xFFF08A, 0xA6D0FF, 0xFFB3FF, 0x8CF7FF, 0xFFFFFF,
        ]
    )

    /// All built-in themes, default first.
    public static let builtIn: [TerminalTheme] = [.tildeNight, .tildeDay, .midnightHighContrast]

    /// The theme with this id, or the default.
    public static func theme(withID id: String) -> TerminalTheme {
        builtIn.first { $0.id == id } ?? .tildeNight
    }
}
