import SwiftUI

/// Typography helpers (docs/DESIGN.md section 2.3): SF Mono for every machine-readable value,
/// SF Pro for chrome.
public enum TildeFont {
    /// Monospaced system font (SF Mono). Use for hostnames, users, ports, fingerprints, key material.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Server name in lists (SF Mono 15 semibold).
    public static let rowTitle = mono(15, weight: .semibold)
    /// `deploy@10.0.1.12:22` under the name (SF Mono 12).
    public static let rowSubtitle = mono(12)
    /// Latency `23ms` (SF Mono 11).
    public static let caption = mono(11)
    /// Environment badge (caps 10 pt).
    public static let badge = mono(10, weight: .bold)
    /// Mac sidebar row: server name in SF Mono 12 medium.
    public static let sidebarRow = mono(12, weight: .medium)
    /// Mac sidebar row latency and counts (SF Mono 11), tertiary text.
    public static let sidebarCaption = mono(11)
    /// Mac sidebar footer and section header chrome (SF Pro 11).
    public static let sidebarChrome = Font.system(size: 11)
    /// Compact environment badge for sidebar rows and tabs (caps 9 pt).
    public static let badgeCompact = mono(9, weight: .bold)
    /// Section headers: caps, 11 pt, +0.6 tracking, text3. Apply with `.tildeSectionHeader()`.
    public static let sectionHeader = Font.system(size: 11, weight: .semibold)
}

public extension Font {
    /// `Font.tildeMono(13)`.
    static func tildeMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { TildeFont.mono(size, weight: weight) }
}

public struct TildeSectionHeaderStyle: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content
            .font(TildeFont.sectionHeader)
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(TildeColor.text3)
    }
}

public extension View {
    /// Section header look: caps, 11 pt, +0.6 tracking, `text3`.
    func tildeSectionHeader() -> some View { modifier(TildeSectionHeaderStyle()) }
}
