import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public extension Color {
    /// A colour from `0xRRGGBB` or, with `hasAlpha`, `0xRRGGBBAA`.
    init(hex: UInt32, hasAlpha: Bool = false) {
        let (r, g, b, a) = Color.components(hex, hasAlpha: hasAlpha)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// An appearance-aware colour built in code (no asset catalog needed).
    /// Values are `0xRRGGBB`, or `0xRRGGBBAA` when `hasAlpha` is true.
    init(dark: UInt32, light: UInt32, hasAlpha: Bool = false) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            let (r, g, b, a) = Color.components(traits.userInterfaceStyle == .dark ? dark : light, hasAlpha: hasAlpha)
            return UIColor(red: r, green: g, blue: b, alpha: a)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (r, g, b, a) = Color.components(isDark ? dark : light, hasAlpha: hasAlpha)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        })
        #endif
    }

    private static func components(_ hex: UInt32, hasAlpha: Bool) -> (Double, Double, Double, Double) {
        if hasAlpha {
            return (Double((hex >> 24) & 0xFF) / 255, Double((hex >> 16) & 0xFF) / 255,
                    Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        return (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, 1)
    }
}
