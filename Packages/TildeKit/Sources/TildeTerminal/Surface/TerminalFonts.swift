import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
#else
import AppKit
typealias PlatformFont = NSFont
#endif

/// Font lookup for the terminal. SF Mono and Menlo ship with the OS. JetBrains Mono Nerd Font Mono is an
/// optional extra: any `.ttf`/`.otf` placed in the app bundle (`App/Resources/Fonts`) is registered at
/// first use, and a choice whose font is missing falls back to SF Mono.
enum TerminalFonts {
    /// PostScript names tried for each bundled face.
    private static let jetBrainsNames = ["JetBrainsMonoNFM-Regular", "JetBrainsMonoNerdFontMono-Regular", "JetBrainsMono-Regular"]

    private static let registration: Void = {
        let bundle = Bundle.main
        var urls: [URL] = []
        for ext in ["ttf", "otf"] {
            urls += bundle.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? []
            urls += bundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    /// Registers fonts found in the app bundle. Safe to call repeatedly.
    static func registerBundledFonts() { _ = registration }

    /// Whether the JetBrains Mono Nerd Font is available (bundled or installed).
    static var isJetBrainsAvailable: Bool {
        registerBundledFonts()
        return jetBrainsNames.contains { PlatformFont(name: $0, size: 12) != nil }
    }

    /// The font for a choice at a size; never nil.
    static func font(_ choice: TerminalFontChoice, size: Double) -> PlatformFont {
        registerBundledFonts()
        let pt = CGFloat(size)
        switch choice {
        case .sfMono:
            return PlatformFont.monospacedSystemFont(ofSize: pt, weight: .regular)
        case .menlo:
            return PlatformFont(name: "Menlo-Regular", size: pt) ?? PlatformFont.monospacedSystemFont(ofSize: pt, weight: .regular)
        case .jetBrainsMonoNF:
            for name in jetBrainsNames {
                if let font = PlatformFont(name: name, size: pt) { return font }
            }
            return PlatformFont.monospacedSystemFont(ofSize: pt, weight: .regular)
        }
    }
}
