import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// Wraps one window's content with everything every window needs: an `AppNavigator`, the sheet host, host-key and
/// password prompts, keyboard-shortcut actions (`SessionCommandActions`), and `ssh://` URL handling.
///
/// Requires `SessionCoordinator` in the environment (`TildeApp` injects it).
public struct WindowHost<Content: View>: View {
    @Environment(SessionCoordinator.self) private var coordinator
    private let windowID: UUID?
    private let content: Content

    /// - Parameter windowID: the window's id. `nil` creates a fresh one (main windows). A detached session window
    ///   passes the id of the tab it shows.
    public init(windowID: UUID? = nil, @ViewBuilder content: () -> Content) {
        self.windowID = windowID
        self.content = content()
    }

    public var body: some View {
        WindowHostBody(coordinator: coordinator, windowID: windowID ?? UUID(), content: content)
    }
}

private struct WindowHostBody<Content: View>: View {
    @State private var navigator: AppNavigator
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    let coordinator: SessionCoordinator
    let content: Content

    init(coordinator: SessionCoordinator, windowID: UUID, content: Content) {
        self.coordinator = coordinator
        self.content = content
        _navigator = State(initialValue: AppNavigator(coordinator: coordinator, windowID: windowID))
    }

    var body: some View {
        @Bindable var navigator = navigator
        content
            .modifier(SessionPromptHost(suppressed: navigator.sheet != nil || coordinator.isDeckPresented))
            .sheet(item: $navigator.sheet) { sheet in
                AppSheetView(sheet: sheet)
            }
            .focusedSceneValue(\.sessionActions, commandActions)
            .onChange(of: coordinator.saveServerRequest) { _, request in
                guard let request else { return }
                coordinator.saveServerRequest = nil
                navigator.present(.saveServer(request))
            }
            .onOpenURL { url in
                guard url.scheme?.lowercased() == "ssh" else { return }
                QuickConnectLauncher(services: services, context: context, navigator: navigator).connect(url.absoluteString)
            }
            // Outermost, so every modifier above (and the sheets) can read the navigator.
            .environment(navigator)
    }

    private var commandActions: SessionCommandActions {
        let navigator = navigator
        let coordinator = coordinator
        let window = navigator.windowID
        return SessionCommandActions(
            hasTabs: !navigator.tabs.isEmpty,
            canReopenClosed: !coordinator.recentlyClosed.isEmpty,
            newTab: { navigator.present(.palette(.newTab)) },
            closeTab: { coordinator.closeSelected(in: window) },
            reopenClosedTab: { navigator.reopenLastClosed() },
            selectTab: { coordinator.select(index: $0, in: window) },
            nextTab: { coordinator.selectNext(in: window) },
            previousTab: { coordinator.selectPrevious(in: window) },
            commandPalette: { navigator.present(.palette(.all)) },
            snippetPalette: { navigator.present(.palette(.snippets)) },
            quickConnect: { navigator.focusSearch() },
            newServer: { navigator.present(.newServer) },
            reconnect: { if let tab = navigator.selectedTab { coordinator.reconnect(tab) } },
            disconnect: { coordinator.closeSelected(in: window) },
            showSettings: { navigator.present(.settings) }
        )
    }
}

// MARK: - Prompts

/// Shows the engine's questions: the unknown-host sheet, the password sheet, and the changed-key takeover. Attach it
/// to the window root and to anything presented over it (the deck, the editor), because a sheet cannot present
/// over another presentation.
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
                SSHConfigImportView { hosts in
                    if !hosts.isEmpty { ServerActions(context: context, secrets: services.secretStore).importHosts(hosts) }
                    dismiss()
                }
            case .newSnippet:
                SnippetEditor()
            case .editSnippet(let id):
                if let snippet = snippet(id) { SnippetEditor(snippet: snippet) } else { Color.clear.onAppear { dismiss() } }
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
