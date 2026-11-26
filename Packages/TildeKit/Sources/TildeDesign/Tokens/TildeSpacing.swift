import CoreGraphics

/// Spacing and size tokens. Values in points.
public enum TildeSpacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32

    /// List rows: 44 pt on iOS, 28 pt on Mac (docs/DESIGN.md section 4).
    public static let rowHeightTouch: CGFloat = 44
    public static let rowHeightMac: CGFloat = 28
    /// Terminal inner padding (the theme background fills it; the emulator grid is sized to what is left).
    public static let terminalPadding: CGFloat = 4
    /// Terminal inset on iPad and Mac, where there is room to breathe.
    public static let terminalInsetHorizontal: CGFloat = 12
    public static let terminalInsetVertical: CGFloat = 8
    /// Terminal inset on iPhone, where every column counts.
    public static let terminalInsetHorizontalCompact: CGFloat = 8
    public static let terminalInsetVerticalCompact: CGFloat = 4
    /// Hairline border width.
    public static let hairline: CGFloat = 0.5
    /// Environment stripe on the top edge of tabs and the title bar.
    public static let envStripe: CGFloat = 2
    public static let statusDot: CGFloat = 8
    public static let titleBarHeight: CGFloat = 36
    /// Key bar heights: iPhone 46, iPad 52, hardware-keyboard strip 32.
    public static let keyBarPhone: CGFloat = 46
    public static let keyBarPad: CGFloat = 52
    public static let keyBarSlim: CGFloat = 32
}

/// Corner radii.
public enum TildeRadius {
    public static let key: CGFloat = 6
    public static let badge: CGFloat = 4
    public static let card: CGFloat = 10
    public static let sheet: CGFloat = 16
}
