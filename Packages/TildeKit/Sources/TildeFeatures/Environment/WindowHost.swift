import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeSecurity
import TildeStore
import TildeTerminal

/// "Tilde > Lock Now": the app shell sets this to `appLock.lockNow` (the lock itself is owned by the security module).
public struct LockNowAction: Sendable {
    private let run: @MainActor @Sendable () -> Void
    public init(_ run: @escaping @MainActor @Sendable () -> Void) { self.run = run }
    @MainActor public func callAsFunction() { run() }
}

public extension EnvironmentValues {
    @Entry var lockNowAction: LockNowAction?
}

/// Wraps one window's content with everything every window needs: its `AppNavigator`, the sheet host, host-key
/// and password prompts, the menu-bar actions (`WindowCommandActions` / `SessionCommandActions`), and
/// `ssh://` / `tilde://` link handling.
///
/// Requires `SessionCoordinator` in the environment (`TildeApp` injects it).
public struct WindowHost<Content: View>: View {
    @Environment(SessionCoordinator.self) private var coordinator
    /// Fallback id for main windows; stable for the life of the view.
    @State private var ownID = UUID()
    private let windowID: UUID?
    private let content: Content

    /// - Parameter windowID: the window's id. `nil` gives the window an id of its own (main windows). A detached
    ///   session window passes the id of the tab it shows.
    public init(windowID: UUID? = nil, @ViewBuilder content: () -> Content) {
        self.windowID = windowID
        self.content = content()
    }

    public var body: some View {
        let id = windowID ?? ownID
        WindowHostBody(navigator: coordinator.navigator(for: id), content: content)
            .onDisappear { coordinator.windowClosed(id) }
    }
}

private struct WindowHostBody<Content: View>: View {
    let navigator: AppNavigator
    let content: Content

    @Environment(\.openWindow) private var openWindow
    @Environment(\.lockNowAction) private var lockNow
    /// Set by `AppLockGate`. While it is locked the menu bar offers nothing that acts on content: the cover blocks
    /// pointer and touch input, but menu shortcuts and menu items would still reach the actions published below.
    @Environment(\.tildeAppLock) private var appLock

    private var coordinator: SessionCoordinator { navigator.coordinator }

    var body: some View {
        @Bindable var navigator = navigator
        content
            .modifier(SessionPromptHost(suppressed: navigator.sheet != nil || navigator.isDeckPresented))
            .modifier(AppSheetHost(isActive: !navigator.isDeckPresented))
            .windowCommandActions(windowActions)
            .sessionCommandActions(sessionActions)
            .onChange(of: coordinator.saveServerRequest) { _, request in
                guard let request else { return }
                coordinator.saveServerRequest = nil
                navigator.present(.saveServer(request))
            }
            .onOpenURL { navigator.handleLink($0) }
            // Outermost, so every modifier above (and the sheets) can read the navigator.
            .environment(navigator)
    }

    // MARK: Menu bar actions

    private var windowActions: WindowCommandActions {
        let navigator = navigator
        let coordinator = coordinator
        let window = navigator.windowID
        let tabs = navigator.tabs
        let selected = navigator.selectedTab
        let opener = WindowOpener(action: openWindow)

        var actions = WindowCommandActions()
        if appLock?.isLocked == true { return actions }
        actions.newTab = { navigator.present(.palette(.newTab)) }
        if !coordinator.recentlyClosed.isEmpty { actions.reopenClosedTab = { navigator.reopenLastClosed() } }
        if !tabs.isEmpty { actions.closeTab = { coordinator.closeSelected(in: window) } }
        actions.newServer = { navigator.present(.newServer) }
        actions.quickConnect = { navigator.focusSearch() }
        actions.commandPalette = { navigator.present(.palette(.all)) }
        actions.importSSHConfig = { navigator.present(.importSSHConfig) }
        actions.importKnownHosts = { navigator.present(.importKnownHosts) }
        actions.tabCount = tabs.count
        actions.selectedTabIndex = selected.flatMap { tab in tabs.firstIndex { $0.id == tab.id } }
        actions.selectTab = { coordinator.select(index: $0 + 1, in: window) }
        if tabs.count > 1 {
            actions.selectPreviousTab = { coordinator.selectPrevious(in: window) }
            actions.selectNextTab = { coordinator.selectNext(in: window) }
        }
        if let tab = selected {
            actions.moveTabToNewWindow = {
                let id = coordinator.moveToOwnWindow(tab)
                opener.open(SessionWindowValue(sessionID: id))
            }
        }
        // View > Bigger / Smaller / Actual Size act on the selected tab's terminal; a size change there also updates
        // the saved font size (`TerminalSurface` reports it). Themes are a saved setting, so any window can change them.
        if let terminal = selected?.terminal {
            actions.increaseFontSize = { terminal.increaseFontSize() }
            actions.decreaseFontSize = { terminal.decreaseFontSize() }
            actions.resetFontSize = { terminal.resetFontSize() }
        }
        let terminalSettings = TerminalSettings.shared
        actions.themes = TerminalTheme.builtIn.map { ThemeChoice(id: $0.id, name: $0.name) }
        actions.selectedThemeID = terminalSettings.theme.id
        actions.selectTheme = { terminalSettings.themeID = $0 }
        #if !os(macOS)
        // On the Mac the system's own sidebar toggle handles this; on iPad the split view column is ours to flip.
        if !navigator.isCompact { actions.toggleSidebar = { navigator.toggleSidebar() } }
        #endif
        actions.showKeys = { navigator.present(.keys) }
        actions.showSnippets = { navigator.present(.snippets) }
        if let lockNow { actions.lockNow = { lockNow() } }
        return actions
    }

    private var sessionActions: SessionCommandActions? {
        guard appLock?.isLocked != true, let tab = navigator.selectedTab else { return nil }
        let navigator = navigator
        let coordinator = coordinator
        var actions = SessionCommandActions()
        actions.reconnect = { coordinator.reconnect(tab) }
        actions.disconnect = { coordinator.close(tab) }
        let terminal = tab.terminal
        actions.clear = { terminal.clear() }
        actions.clearScrollback = { terminal.clearScrollback() }
        actions.sendInterrupt = { terminal.sendInterrupt() }
        actions.find = { terminal.showFind() }
        actions.findNext = { terminal.findNext() }
        actions.findPrevious = { terminal.findPrevious() }
        if tab.isAdHoc {
            actions.editServer = { navigator.saveAsServer(tab) }
        } else {
            actions.editServer = { navigator.present(.editServer(tab.server.id)) }
        }
        actions.copySSHCommand = { Platform.copy(SSHCommand.string(for: tab.server)) }
        actions.pasteSnippet = { navigator.present(.palette(.snippets)) }
        return actions
    }
}

/// `OpenWindowAction` is only ever called on the main actor (from menu actions); the box lets a `@Sendable` closure hold it.
private struct WindowOpener: @unchecked Sendable {
    let action: OpenWindowAction

    @MainActor
    func open(_ value: SessionWindowValue) { action(id: "session", value: value) }
}

// MARK: - Prompts

/// Shows the engine's questions: the unknown-host sheet, the password sheet, and the changed-key takeover. Attach it
/// to the window root and to anything presented over it (the deck, sheets), because a sheet cannot present over
/// another presentation. `suppressed` hands a window's prompts to the presentation that is on top.
struct SessionPromptHost: ViewModifier {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator
    var suppressed = false

    private enum Prompt: Identifiable {
        case unknownHost(HostKeyRequest)
        case password(PasswordRequest)

        var id: UUID {
            switch self {
            case .unknownHost(let request): request.id
            case .password(let request): request.id
            }
        }
    }

    func body(content: Content) -> some View {
        let hostKey = suppressed ? nil : coordinator.pendingHostKey(in: navigator.windowID)
        content
            .overlay {
                if let hostKey, hostKey.isChangedKey {
                    ChangedHostKeyTakeover(request: hostKey) { coordinator.answerHostKey(hostKey, $0) }
                        .id(hostKey.id)
                        .transition(.opacity)
                        .zIndex(1000)
                }
            }
            .animation(.easeOut(duration: 0.2), value: hostKey?.id)
            .sheet(item: promptBinding(hostKey: hostKey)) { prompt in
                switch prompt {
                case .unknownHost(let request):
                    UnknownHostSheet(request: request) { coordinator.answerHostKey(request, $0) }
                        .presentationDetents([.medium, .large])
                case .password(let request):
                    PasswordPromptSheet(request: request) { password, save, update in
                        coordinator.answerPassword(request, password: password, saveServer: save, updateSaved: update)
                    }
                }
            }
    }

    private func promptBinding(hostKey: HostKeyRequest?) -> Binding<Prompt?> {
        Binding(
            get: {
                if let hostKey, !hostKey.isChangedKey { return .unknownHost(hostKey) }
                if !suppressed, let password = coordinator.pendingPassword(in: navigator.windowID) { return .password(password) }
                return nil
            },
            set: { _ in }   // dismissal is disabled; answers go through the coordinator
        )
    }
}

// MARK: - Sheets

/// Presents the window's `AppSheet`. `isActive` is `false` while a deck covers the window: the deck hosts the sheets
/// then, because a sheet cannot present over a full-screen cover.
struct AppSheetHost: ViewModifier {
    @Environment(AppNavigator.self) private var navigator
    let isActive: Bool

    func body(content: Content) -> some View {
        @Bindable var navigator = navigator
        content.sheet(item: Binding(
            get: { isActive ? navigator.sheet : nil },
            set: { navigator.sheet = $0 }
        )) { sheet in
            AppSheetView(sheet: sheet)
        }
    }
}

/// Routes an `AppSheet` to its view and fetches the model it names.
struct AppSheetView: View {
    let sheet: AppSheet
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        Group {
            switch sheet {
            case .newServer:
                #if os(macOS)
                MacServerEditor()
                #else
                ServerEditor()
                #endif
            case .editServer(let id):
                #if os(macOS)
                if let server = server(id) { MacServerEditor(server: server) } else { Color.clear.onAppear { dismiss() } }
                #else
                if let server = server(id) { ServerEditor(server: server) } else { Color.clear.onAppear { dismiss() } }
                #endif
            case .saveServer(let request):
                #if os(macOS)
                MacServerEditor(prefill: request)
                #else
                ServerEditor(prefill: request)
                #endif
            case .palette(let mode):
                CommandPalette(mode: mode)
            case .keys:
                #if os(macOS)
                // On the Mac the list draws its own TildeSheet action bar (with Done), so no toolbar Done here.
                NavigationStack { KeyListView() }
                #else
                NavigationStack { KeyListView().toolbar { doneButton } }
                #endif
            case .snippets:
                #if os(macOS)
                NavigationStack { SnippetList() }
                #else
                NavigationStack { SnippetList().toolbar { doneButton } }
                #endif
            case .settings:
                SettingsRoot(showsDone: true)
            case .generateKey:
                GenerateKeySheet()
            case .importSSHConfig:
                let actions = ServerActions(context: context, secrets: services.secretStore)
                SSHConfigImportView(existingServers: actions.savedSnapshots(), onFinish: { hosts in
                    if !hosts.isEmpty { actions.importHosts(hosts) }
                    dismiss()
                })
            case .importKnownHosts:
                KnownHostsImportView { _ in dismiss() }
            case .newSnippet:
                SnippetEditor()
            case .editSnippet(let id):
                if let snippet = snippet(id) { SnippetEditor(snippet: snippet) } else { Color.clear.onAppear { dismiss() } }
            case .confirmLink(let result):
                LinkConnectSheet(target: result.target) {
                    dismiss()
                    QuickConnectLauncher(services: services, context: context, navigator: navigator).connectFromLink(result)
                } onCancel: {
                    dismiss()
                }
            }
        }
        .modifier(SessionPromptHost())
        .presentationBackground(TildeColor.bg)
    }

    @ToolbarContentBuilder
    private var doneButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
    }

    private func server(_ id: UUID) -> Server? {
        var descriptor = FetchDescriptor<Server>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func snippet(_ id: UUID) -> Snippet? {
        var descriptor = FetchDescriptor<Snippet>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// "Connect to deploy@10.0.4.12:2222?" for a link. A link is untrusted input: the sheet shows exactly where it
/// points, and the connection that follows uses a password prompt only (no default key, no saved server settings).
struct LinkConnectSheet: View {
    let target: ConnectionTarget
    let onConnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        TildeSheet("Connect to \(target.displayString)?", size: .compact, scrolls: false) {
            VStack(alignment: .leading, spacing: TildeSpacing.l) {
                Text("A link asked Tilde to open this connection. Check the address before you continue. You will be asked for a password; no saved key or server settings are used.")
                    .tildeText(14, relativeTo: .subheadline)
                    .foregroundStyle(TildeColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(TildeSheetMetrics.padding)
        } actions: {
            TildeCancelButton(action: onCancel)
            // The address came from outside the app, so connecting takes a click, not a stray Return.
            TildeDefaultButton("Connect", requiresClick: true, action: onConnect)
        }
        .interactiveDismissDisabled()
        .presentationDetents([.medium])
        .accessibilityElement(children: .contain)
    }
}
