import Foundation
import QuartzCore
import SwiftTerm
import Testing
import TildeCore
@testable import TildeTerminal

/// The terminal paints its background through the view's layer; a nil layer colour renders black.
@Suite @MainActor struct TerminalBackgroundTests {
    @Test func themeBackgroundReachesTheLayer() throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        for theme in TerminalTheme.builtIn {
            view.applyTheme(theme, environment: .dev)
            let layer = try #require(view.layer as CALayer?)
            let actual = try #require(layer.backgroundColor)
            let expected = TerminalView.nativeColor(theme.background).cgColor
            #expect(actual.components == expected.components, "theme \(theme.id)")
            #expect(actual.alpha == 1)
        }
    }
}
