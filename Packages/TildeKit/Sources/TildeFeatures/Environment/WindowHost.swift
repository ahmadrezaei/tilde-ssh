import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

public extension EnvironmentValues {
    /// "Tilde > Lock Now": set by the app shell to `appLock.lockNow` (the lock itself is owned by WS3).
    @Entry var lockNowAction: (@MainActor @Sendable () -> Void)?
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

    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Environment(\.openWindow) private var openWindow
    @Environment(\.lockNowAction) private var lockNow

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
            .onOpenURL(perform: handle)
            // Outermost, so every modifier above (and the sheets) can read the navigator.
            .environment(navigator)
    }

    // MARK: Links

    /// `ssh://` and `tilde://` links never connect by themselves: they raise a confirmation first.
    private func handle(_ url: URL) {
        let parser = TildeURLParser(defaultUsername: TildeSettings.currentDefaultUser)
        switch parser.parse(url) {
        case .connect(let result):
            navigator.present(.confirmLink(result))
        case .newServer(let result, let name):
            let snapshot = ServerSnapshot(name: name ?? result.target.host, target: result.target, auth: .passwordPrompt)
            navigator.present(.saveServer(SaveServerRequest(server: snapshot, password: nil)))
        case .show(let destination):
            navigator.show(destination)
        case nil:
            break
        }
    }

    // MARK: Menu bar actions

    private var windowActions: WindowCommandActions {
        let navigator = navigator
        let coordinator = coordinator
        let window = navigator.windowID
        let tabs = navigator.tabs
        let openWindow = openWindow
        let selected = navigator.selectedTab
        return WindowCommandActions(
            newTab: { navigator.present(.palette(.newTab)) },
            reopenClosedTab: coordinator.recentlyClosed.isEmpty ? nil : { navigator.reopenLastClosed() },
            closeTab: tabs.isEmpty ? nil : { coordinator.closeSelected(in: window) },
            newServer: { navigator.present(.newServer) },
            quickConnect: { navigator.focusSearch() },
            commandPalette: { navigator.present(.palette(.all)) },
            importSSHConfig: { navigator.present(.importSSHConfig) },
            importKnownHosts: { navigator.present(.importKnownHosts) },
            tabCount: tabs.count,
            selectedTabIndex: selected.flatMap { tab in tabs.firstIndex { $0.id == tab.id } },
            selectTab: { coordinator.select(index: $0 + 1, in: window) },
            selectPreviousTab: tabs.count > 1 ? { coordinator.selectPrevious(in: window) } : nil,
            selectNextTab: tabs.count > 1 ? { coordinator.selectNext(in: window) } : nil,
            moveTabToNewWindow: selected.map { tab in
                { let id = coordinator.moveToOwnWindow(tab); openWindow(id: "session", value: SessionWindowValue(sessionID: id)) }
            },
            showKeys: { navigator.present(.keys) },
            showSnippets: { navigator.present(.snippets) },
            lockNow: lockNow
        )
    }

    private var sessionActions: SessionCommandActions? {
        guard let tab = navigator.selectedTab else { return nil }
        let navigator = navigator
        let coordinator = coordinator
        return SessionCommandActions(
            reconnect: { coordinator.reconnect(tab) },
            disconnect: { coordinator.close(tab) },
            sendInterrupt: { tab.terminalIO.send(Data([0x03])) },
            editServer: tab.isAdHoc ? { navigator.saveAsServer(tab) } : { navigator.present(.editServer(tab.server.id)) },
            copySSHCommand: { Platform.copy(SSHCommand.string(for: tab.server)) },
            pasteSnippet: { navigator.present(.palette(.snippets)) }
        )
    }
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
                        .modifier(SheetSizing())
                case .password(let request):
                    PasswordPromptSheet(request: request) { password, save, update in
                        coordinator.answerPassword(request, password: password, saveServer: save, updateSaved: update)
                    }
                    .modifier(SheetSizing())
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

private struct SheetSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(minWidth: 460, minHeight: 360)
        #else
        content
        #endif
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
                ServerEditor()
            case .editServer(let id):
                if let server = server(id) { ServerEditor(server: server) } else { Color.clear.onAppear { dismiss() } }
            case .saveServer(let request):
                ServerEditor(prefill: request)
            case .palette(let mode):
                CommandPalette(mode: mode)
            case .keys:
                NavigationStack { KeyListView().toolbar { doneButton } }
            case .snippets:
                NavigationStack { SnippetList().toolbar { doneButton } }
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
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
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
        VStack(alignment: .leading, spacing: TildeSpacing.l) {
            Text("Connect to \(target.displayString)?")
                .tildeMono(18, weight: .bold, relativeTo: .headline)
                .foregroundStyle(TildeColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("A link asked Tilde to open this connection. Check the address before you continue. You will be asked for a password; no saved key or server settings are used.")
                .tildeText(14, relativeTo: .subheadline)
                .foregroundStyle(TildeColor.text2)
            Spacer(minLength: 0)
            Button("Connect", action: onConnect).buttonStyle(.tildePrimary).keyboardShortcut(.defaultAction)
            Button("Cancel", action: onCancel).buttonStyle(.tildeSecondary).keyboardShortcut(.cancelAction)
        }
        .padding(TildeSpacing.l)
        .background(TildeColor.bg)
        .interactiveDismissDisabled()
        .presentationDetents([.medium])
        .accessibilityElement(children: .contain)
    }
}
