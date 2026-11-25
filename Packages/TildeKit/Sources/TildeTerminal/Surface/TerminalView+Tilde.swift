import Foundation
import SwiftTerm
import TildeCore
#if canImport(UIKit)
import UIKit
typealias NativeColor = UIColor
#else
import AppKit
typealias NativeColor = NSColor
#endif

/// Shared configuration of a SwiftTerm `TerminalView` (both platforms): colours, font, cursor, bell, behaviour.
extension TerminalView {
    /// `0xRRGGBB` to a native colour.
    static func nativeColor(_ rgb: UInt32, alpha: CGFloat = 1) -> NativeColor {
        NativeColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static func termColor(_ rgb: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16((rgb >> 16) & 0xFF), green8: UInt16((rgb >> 8) & 0xFF), blue8: UInt16(rgb & 0xFF))
    }

    /// The cursor colour for a theme. PROD servers get a red cursor so the terminal itself looks dangerous.
    static func cursorRGB(theme: TerminalTheme, environment: ServerEnvironment) -> UInt32 {
        environment == .prod ? 0xF7525F : theme.cursor
    }

    func applyTheme(_ theme: TerminalTheme, environment: ServerEnvironment) {
        installColors(theme.ansi.map(Self.termColor))
        nativeForegroundColor = Self.nativeColor(theme.foreground)
        // Only `nativeBackgroundColor`: SwiftTerm paints the view background through its layer, and assigning the
        // UIKit `backgroundColor` as well would leave that layer colour nil, which renders black.
        nativeBackgroundColor = Self.nativeColor(theme.background)
        caretColor = Self.nativeColor(Self.cursorRGB(theme: theme, environment: environment))
        // The theme stores the selection as 0xRRGGBBAA.
        selectedTextBackgroundColor = Self.nativeColor(theme.selection >> 8, alpha: CGFloat(theme.selection & 0xFF) / 255)
        selectedTextForegroundColor = Self.nativeColor(theme.foreground)
        // Bold does not turn colours bright (docs/DESIGN.md section 2.4); explicit bright colours stay as sent.
        useBrightColors = false
        collapseBrightColorsToBase = false
        #if canImport(UIKit)
        indicatorStyle = theme.isDark ? .white : .black
        keyboardAppearance = theme.isDark ? .dark : .light
        #endif
    }

    /// Pixels per point of the screen this view is on.
    var currentBackingScale: CGFloat {
        #if canImport(UIKit)
        window?.screen.scale ?? traitCollection.displayScale
        #else
        window?.backingScaleFactor ?? 1
        #endif
    }

    func applyFont(_ choice: TerminalFontChoice, size: Double) {
        font = TerminalFonts.font(choice, size: TerminalAppearance.clamp(size))
    }

    func applyCursor(shape: TerminalCursorShape, blink: Bool) {
        let style: CursorStyle
        switch (shape, blink) {
        case (.block, false): style = .steadyBlock
        case (.block, true): style = .blinkBlock
        case (.bar, false): style = .steadyBar
        case (.bar, true): style = .blinkBar
        case (.underline, false): style = .steadyUnderline
        case (.underline, true): style = .blinkUnderline
        }
        setCursorStyle(style)
    }

    func applyBell(_ mode: TerminalBellMode) {
        switch mode {
        case .haptic: bellStyle = .sound
        case .visual: bellStyle = .visual
        case .off: bellStyle = .none
        }
    }

    func applyBehavior(_ behavior: TerminalBehavior) {
        allowMouseReporting = behavior.mouseReporting
        copyOnSelect = behavior.copyOnSelect ? .clipboard : .off
    }
}
