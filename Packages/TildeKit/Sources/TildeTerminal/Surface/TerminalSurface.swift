import SwiftUI
import TildeCore
import TildeDesign

/// The terminal view: SwiftTerm (`TerminalView` on UIKit and AppKit) plus the key bar on touch devices.
///
/// Placeholder: WS4 replaces the body with the real wrappers. The initializer signature is the contract
/// consumed by `SessionContainer` (WS5), so keep it stable.
///
/// - Parameters:
///   - io: the remote byte stream (a `TerminalSession`, or `EchoTerminalSession` in previews).
///   - theme: colours.
///   - environment: drives the PROD stripe and the multi-line paste guard.
///   - keyBar: key bar layout and keyboard behaviour.
///   - snippets: source for the key bar's snippet palette.
///   - onFontSizeChange: called when the user pinches or uses the Cmd +/- shortcuts.
public struct TerminalSurface: View {
    public let io: any TerminalIO
    public let theme: TerminalTheme
    public let environment: ServerEnvironment
    public let keyBar: KeyBarConfiguration
    public let snippets: any SnippetProviding
    public let onFontSizeChange: (Double) -> Void

    public init(
        io: any TerminalIO,
        theme: TerminalTheme = .tildeNight,
        environment: ServerEnvironment = .none,
        keyBar: KeyBarConfiguration = .default,
        snippets: any SnippetProviding,
        onFontSizeChange: @escaping (Double) -> Void = { _ in }
    ) {
        self.io = io
        self.theme = theme
        self.environment = environment
        self.keyBar = keyBar
        self.snippets = snippets
        self.onFontSizeChange = onFontSizeChange
    }

    public var body: some View {
        ZStack {
            Color(hex: theme.background)
            Text("~ $ _")
                .font(TildeFont.mono(20, weight: .semibold))
                .foregroundStyle(Color(hex: theme.cursor))
        }
        .accessibilityLabel("Terminal")
    }
}

#Preview("TerminalSurface") {
    TerminalSurface(io: EchoTerminalSession(server: PreviewServers.prodAPI), snippets: StaticSnippetProvider())
}
