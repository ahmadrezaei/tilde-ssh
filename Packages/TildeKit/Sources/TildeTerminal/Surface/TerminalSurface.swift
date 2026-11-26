import SwiftUI
import TildeCore
import TildeDesign

/// The terminal view: SwiftTerm (`TerminalView` on UIKit and AppKit) wired to a `TerminalIO`, plus the key bar
/// on touch devices.
///
/// The surface feeds `io.output` to the emulator, sends typed input to `io.send`, and reports size changes with
/// `io.resize`. It keeps the emulator (screen and scrollback) alive per session, so rebuilding the SwiftUI view,
/// for instance when switching tabs, does not lose output.
///
/// - Parameters:
///   - io: the remote byte stream (a `TerminalSession`, or `EchoTerminalSession` in previews).
///   - theme: colours.
///   - environment: drives the PROD cursor and edge accent and the multi-line paste guard.
///   - keyBar: key bar layout and keyboard behaviour.
///   - snippets: source for the key bar's snippet palette.
///   - onFontSizeChange: called when the user pinches or uses the Cmd +/- shortcuts.
///   - appearance: font, size, cursor and bell. `appearance.fontSize` applies whenever it changes; pinch changes
///     stay local until the caller passes a different value.
///   - behavior: scrollback, paste confirmation, OSC 52 policy, mouse reporting, copy on select.
///   - controller: a handle for the menu bar and session menu (find, clear, font size, copy/paste, send).
///   - onConfirmPaste: asked before a multi-line paste when `behavior.pasteConfirmation` requires it for this
///     environment. Return `true` to paste. When nil, the surface shows a simple alert.
///   - onTitleChange: called when the remote program sets the window title (OSC 0/2).
public struct TerminalSurface: View {
    public let io: any TerminalIO
    public let theme: TerminalTheme
    public let environment: ServerEnvironment
    public let keyBar: KeyBarConfiguration
    public let snippets: any SnippetProviding
    public let onFontSizeChange: (Double) -> Void
    public let appearance: TerminalAppearance
    public let behavior: TerminalBehavior
    public let controller: TerminalController?
    public let onConfirmPaste: (@MainActor (PasteRequest) async -> Bool)?
    public let onTitleChange: ((String) -> Void)?

    @State private var ownController = TerminalController()
    @Environment(\.horizontalSizeClass) private var sizeClass

    public init(
        io: any TerminalIO,
        theme: TerminalTheme = .tildeNight,
        environment: ServerEnvironment = .none,
        keyBar: KeyBarConfiguration = .default,
        snippets: any SnippetProviding,
        onFontSizeChange: @escaping (Double) -> Void = { _ in },
        appearance: TerminalAppearance = TerminalAppearance(),
        behavior: TerminalBehavior = .default,
        controller: TerminalController? = nil,
        onConfirmPaste: (@MainActor (PasteRequest) async -> Bool)? = nil,
        onTitleChange: ((String) -> Void)? = nil
    ) {
        self.io = io
        self.theme = theme
        self.environment = environment
        self.keyBar = keyBar
        self.snippets = snippets
        self.onFontSizeChange = onFontSizeChange
        self.appearance = appearance
        self.behavior = behavior
        self.controller = controller
        self.onConfirmPaste = onConfirmPaste
        self.onTitleChange = onTitleChange
    }

    /// Builds the surface from the user's saved terminal preferences (theme, font, key bar, behaviour).
    @MainActor
    public init(
        io: any TerminalIO,
        environment: ServerEnvironment = .none,
        settings: TerminalSettings,
        snippets: any SnippetProviding,
        controller: TerminalController? = nil,
        onConfirmPaste: (@MainActor (PasteRequest) async -> Bool)? = nil,
        onTitleChange: ((String) -> Void)? = nil
    ) {
        self.init(
            io: io, theme: settings.theme, environment: environment, keyBar: settings.keyBarConfiguration,
            snippets: snippets, onFontSizeChange: { settings.setFontSize($0) },
            appearance: settings.appearance, behavior: settings.behavior, controller: controller,
            onConfirmPaste: onConfirmPaste, onTitleChange: onTitleChange
        )
    }

    private var activeController: TerminalController { controller ?? ownController }

    /// The inset between the window edge and the character grid. The emulator view is laid out inside it, so SwiftTerm
    /// derives columns and rows (and mouse / selection coordinates) from the smaller frame: nothing is clipped.
    /// `horizontalSizeClass` is nil on the Mac, which counts as regular.
    private var horizontalInset: CGFloat {
        sizeClass == .compact ? TildeSpacing.terminalInsetHorizontalCompact : TildeSpacing.terminalInsetHorizontal
    }

    private var verticalInset: CGFloat {
        sizeClass == .compact ? TildeSpacing.terminalInsetVerticalCompact : TildeSpacing.terminalInsetVertical
    }

    public var body: some View {
        let controller = activeController
        let background = Color(hex: theme.background)
        ZStack {
            background
            TerminalRepresentable(io: io, inputs: inputs(controller))
                .padding(.horizontal, horizontalInset)
                .padding(.vertical, verticalInset)
            if EnvTone(environment) != .none {
                EnvironmentEdge(color: EnvTone(environment).color)
            }
            TerminalOverlays(controller: controller, theme: theme)
        }
    }

    private func inputs(_ controller: TerminalController) -> TerminalSurfaceInputs {
        TerminalSurfaceInputs(
            theme: theme, environment: environment, keyBar: keyBar, appearance: appearance, behavior: behavior,
            snippets: snippets, controller: controller, onFontSizeChange: onFontSizeChange,
            onConfirmPaste: onConfirmPaste, onTitleChange: onTitleChange
        )
    }
}

/// A 2 pt strip on the leading edge in the environment colour (PROD red, STG amber, ...).
private struct EnvironmentEdge: View {
    let color: Color
    var body: some View {
        HStack(spacing: 0) {
            color.frame(width: TildeSpacing.envStripe)
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The modifier HUD, the font size HUD and (on touch devices) the find bar.
private struct TerminalOverlays: View {
    let controller: TerminalController
    let theme: TerminalTheme

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                #if !os(macOS)
                if controller.isFindPresented { FindBar(controller: controller) }
                #endif
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    if let hud = controller.modifierHUDText {
                        ModifierChip(text: hud)
                            .padding(.trailing, 10)
                            .padding(.bottom, 8)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
            if let size = controller.fontSizeHUD {
                Text(size)
                    .font(TildeFont.mono(20, weight: .semibold))
                    .foregroundStyle(TildeColor.text)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: TildeRadius.card))
                    .transition(.opacity)
                    .accessibilityLabel("Font size \(size)")
            }
        }
        .animation(.easeOut(duration: 0.15), value: controller.modifierHUDText)
        .animation(.easeOut(duration: 0.15), value: controller.fontSizeHUD)
    }
}

/// `CTRL`, `CTRL 🔒`, `CTRL+ALT`: shown in the bottom-right corner, just above the key bar.
private struct ModifierChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(TildeFont.mono(11, weight: .bold))
            .foregroundStyle(TildeColor.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(TildeColor.accentSoft, in: Capsule())
            .overlay(Capsule().strokeBorder(TildeColor.accent, lineWidth: 1))
            .accessibilityLabel("Modifier armed: \(text.replacingOccurrences(of: "🔒", with: "locked"))")
    }
}

#if !os(macOS)
/// Find bar for iPhone and iPad (the Mac uses SwiftTerm's own bar).
private struct FindBar: View {
    @Bindable var controller: TerminalController
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(TildeColor.text3)
            TextField("Find in scrollback", text: $controller.findQuery)
                .font(TildeFont.mono(14))
                .noAutocapitalization()
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { controller.findNext() }
                .onChange(of: controller.findQuery) { controller.findNext() }
            if !controller.findStatus.isEmpty {
                Text(controller.findStatus).font(TildeFont.caption).foregroundStyle(TildeColor.text2)
            }
            Button { controller.findNext(forward: false) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel("Previous match")
            Button { controller.findNext(forward: true) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel("Next match")
            Toggle(isOn: $controller.findCaseSensitive) { Text("Aa").font(TildeFont.mono(12, weight: .semibold)) }
                .toggleStyle(.button)
                .accessibilityLabel("Match case")
                .onChange(of: controller.findCaseSensitive) { controller.findNext() }
            Button("Done") { controller.hideFind() }
                .font(.system(size: 14, weight: .semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { TildeColor.border.frame(height: TildeSpacing.hairline) }
        .onAppear { focused = true }
    }
}
#endif

#if os(iOS)
private struct TerminalRepresentable: UIViewRepresentable {
    let io: any TerminalIO
    let inputs: TerminalSurfaceInputs

    final class Coordinator {
        var host: TerminalHost?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TildeTerminalView {
        let host = TerminalHostRegistry.host(for: io, inputs: inputs)
        host.update(inputs)
        host.didAttach()
        context.coordinator.host = host
        return host.view
    }

    func updateUIView(_ view: TildeTerminalView, context: Context) {
        context.coordinator.host?.update(inputs)
    }

    static func dismantleUIView(_ view: TildeTerminalView, coordinator: Coordinator) {
        coordinator.host?.didDetach()
    }
}
#else
private struct TerminalRepresentable: NSViewRepresentable {
    let io: any TerminalIO
    let inputs: TerminalSurfaceInputs

    final class Coordinator {
        var host: TerminalHost?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TildeTerminalView {
        let host = TerminalHostRegistry.host(for: io, inputs: inputs)
        host.update(inputs)
        host.didAttach()
        context.coordinator.host = host
        return host.view
    }

    func updateNSView(_ view: TildeTerminalView, context: Context) {
        context.coordinator.host?.update(inputs)
    }

    static func dismantleNSView(_ view: TildeTerminalView, coordinator: Coordinator) {
        coordinator.host?.didDetach()
    }
}
#endif

// MARK: - Previews

#Preview("Terminal + key bar (echo session)") {
    TerminalPreviewHost(environment: .none)
}

#Preview("Terminal, PROD server") {
    TerminalPreviewHost(environment: .prod)
}

/// A `TerminalSurface` over `EchoTerminalSession`, so the key bar and keyboard can be exercised without a server.
struct TerminalPreviewHost: View {
    var environment: ServerEnvironment
    var theme: TerminalTheme = .tildeNight
    @State private var session = EchoTerminalSession(server: PreviewServers.prodAPI)
    @State private var controller = TerminalController()

    var body: some View {
        TerminalSurface(
            io: session, theme: theme, environment: environment,
            snippets: StaticSnippetProvider(), controller: controller
        )
        .task { await session.connect() }
    }
}
