import SwiftUI

/// Colour tokens from docs/DESIGN.md section 2.2. Dark is the default look; the app forces dark unless
/// Settings > Appearance says otherwise (`preferredColorScheme` is applied by the app shell).
public enum TildeColor {
    public static let bg = Color(dark: 0x0B0F14, light: 0xF6F8FA)
    public static let surface = Color(dark: 0x11161D, light: 0xFFFFFF)
    public static let surface2 = Color(dark: 0x171D25, light: 0xF0F3F6)
    public static let surface3 = Color(dark: 0x1F2630, light: 0xE7EBEF)
    public static let border = Color(dark: 0x262E39, light: 0xD5DBE1)

    public static let text = Color(dark: 0xE6EDF3, light: 0x1F2328)
    public static let text2 = Color(dark: 0x9AA6B2, light: 0x59636E)
    public static let text3 = Color(dark: 0x5F6B78, light: 0x8C959F)

    public static let accent = Color(dark: 0x2DD4BF, light: 0x0F9F8F)
    public static let accentStrong = Color(dark: 0x14B8A6, light: 0x0B7D71)
    /// Selection / armed-key fill (`#2DD4BF24` dark, `#0F9F8F1F` light).
    public static let accentSoft = Color(dark: 0x2DD4BF24, light: 0x0F9F8F1F, hasAlpha: true)

    public static let ok = Color(dark: 0x3FD68B, light: 0x1A7F4B)
    public static let warn = Color(dark: 0xF5B83D, light: 0x9A6700)
    public static let danger = Color(dark: 0xF7525F, light: 0xCF222E)
    public static let info = Color(dark: 0x58A6FF, light: 0x0969DA)
    public static let lab = Color(dark: 0xC792EA, light: 0x8250DF)
}

/// Mirrors `ServerEnvironment` (TildeCore) without depending on it: TildeDesign has no dependencies.
/// TildeFeatures provides `EnvTone.init(_: ServerEnvironment)`.
public enum EnvTone: String, CaseIterable, Sendable {
    case none, dev, staging, prod, lab

    /// `prod -> danger`, `staging -> warn`, `dev -> info`, `lab -> lab`, `none -> text3`.
    public var color: Color {
        switch self {
        case .none: TildeColor.text3
        case .dev: TildeColor.info
        case .staging: TildeColor.warn
        case .prod: TildeColor.danger
        case .lab: TildeColor.lab
        }
    }

    /// Badge text: `PROD`, `STG`, `DEV`, `LAB`; empty for `none`.
    public var badgeLabel: String {
        switch self {
        case .none: ""
        case .dev: "DEV"
        case .staging: "STG"
        case .prod: "PROD"
        case .lab: "LAB"
        }
    }

    public var accessibilityName: String {
        switch self {
        case .none: "No environment"
        case .dev: "Development"
        case .staging: "Staging"
        case .prod: "Production"
        case .lab: "Lab"
        }
    }
}
