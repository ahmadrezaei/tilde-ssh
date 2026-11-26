import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore
import TildeTerminal

/// One session: the terminal surface with state overlays on top (connecting line, reconnect / error banners).
/// Overlays never block the terminal with a modal; the scrollback stays visible, dimmed to 60%.
///
/// The surface reads the saved terminal settings (theme, font, key bar, paste mode), is driven by the tab's
/// `TerminalController` (menu bar, find, font size) and asks the tab's sheet before a multi-line paste.
struct SessionScreen: View {
    let tab: SessionTab

    @Environment(\.tildeServices) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        ZStack(alignment: .top) {
            TerminalSurface(
                io: tab.session,
                environment: tab.environment,
                settings: .shared,
                snippets: services.snippets,
                controller: tab.terminal,
                onConfirmPaste: { await tab.confirmPaste($0) }
            )
            .allowsHitTesting(inTabHostKey == nil)
            .opacity(terminalOpacity)
            .animation(.easeOut(duration: 0.2), value: terminalOpacity)

            VStack(spacing: TildeSpacing.s) {
                if let notice = tab.notice {
                    Banner(.warning, headline: notice.headline, detail: notice.detail,
                           actions: [.init("Dismiss") { tab.notice = nil }])
                }
                // The host-key card replaces the "Connecting…" line while it is up (it is what the handshake waits on).
                if inTabHostKey == nil {
                    SessionStateOverlay(tab: tab, handle: handle)
                }
            }
            .padding(.horizontal, TildeSpacing.m)
            .padding(.top, TildeSpacing.s)

            #if os(macOS)
            if let request = inTabHostKey {
                InTabHostKeyPrompt(tab: tab, request: request)
            }
            #endif
        }
        .background(TildeColor.bg)
        .sheet(item: pasteBinding) { request in
            PasteConfirmationSheet(request: request) { tab.answerPaste($0) }
        }
    }

    /// The unknown-host question to show over this tab (Mac only, and only while the tab is the one on screen: every
    /// tab's screen stays in the tree, and a hidden tab's card must not answer Esc).
    private var inTabHostKey: HostKeyRequest? {
        #if os(macOS)
        // While a sheet is up the card would sit behind it; the sheet's own prompt host shows the question instead.
        guard navigator.sheet == nil, navigator.selectedTab?.id == tab.id else { return nil }
        return coordinator.pendingInTabHostKey(for: tab.id)
        #else
        return nil
        #endif
    }

    private var terminalOpacity: Double {
        if inTabHostKey != nil { return 0.4 }
        return isDimmed ? 0.6 : 1
    }

    private var isDimmed: Bool {
        switch tab.state {
        case .reconnecting, .disconnected: true
        default: false
        }
    }

    private var pasteBinding: Binding<PendingPaste?> {
        Binding(get: { tab.pasteRequest }, set: { if $0 == nil, tab.pasteRequest != nil { tab.answerPaste(false) } })
    }

    private func handle(_ action: SessionErrorAction) {
        switch action {
        case .retry, .tryAgain, .enterOnce: coordinator.reconnect(tab)
        case .edit: edit()
        case .copyPublicKey: copyPublicKey()
        case .installKey: navigator.present(.keys)
        case .copyDetails: copyDetails()
        case .openSyncSettings: navigator.present(.settings)
        case .close: coordinator.close(tab)
        }
    }

    private func edit() {
        if tab.isAdHoc { navigator.saveAsServer(tab) } else { navigator.present(.editServer(tab.server.id)) }
    }

    private func copyPublicKey() {
        guard let keyID = tab.server.keyID else { return }
        let descriptor = FetchDescriptor<SSHKeyRecord>(predicate: #Predicate { $0.privateSecretID == keyID })
        if let key = try? modelContext.fetch(descriptor).first { Platform.copy(key.publicKeyOpenSSH) }
    }

    private func copyDetails() {
        if case .disconnected(.error(let error)) = tab.state {
            Platform.copy(SessionErrorCopy.details(for: error, server: tab.server))
        }
    }
}

#if os(macOS)
/// The scrim and card for an in-tab host-key question. The scrim swallows clicks so the terminal cannot take keyboard
/// focus back, and the terminal is told to let go of it while the card is up. When the question is answered the
/// terminal gets focus again.
private struct InTabHostKeyPrompt: View {
    let tab: SessionTab
    let request: HostKeyRequest
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {}
            // Keyed by request: a jump host asks twice in a row through the same tab, and the second card must be a
            // new view (with its own short grace period) rather than the first one with new text.
            InTabHostKeyCard(request: request) { coordinator.answerHostKey(request, $0) }
                .id(request.id)
                .transition(.opacity)
                .padding(.top, TildeSpacing.xl)
        }
        // Fill the tab, never size it: the prompt must not change the window's minimum size.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
        .onAppear { tab.terminal.resignFocus() }
        .onDisappear {
            // Also fires when the user switches to another tab; only hand focus back if this one is still on screen.
            if navigator.sheet == nil, navigator.selectedTab?.id == tab.id { tab.terminal.focus() }
        }
    }
}
#endif

/// The state overlay: `connecting` is a centred mono line, everything else a banner at the top.
struct SessionStateOverlay: View {
    let tab: SessionTab
    let handle: (SessionErrorAction) -> Void
    @Environment(SessionCoordinator.self) private var coordinator

    var body: some View {
        switch tab.state {
        case .idle:
            connecting(phase: nil)
        case .connecting(let phase):
            connecting(phase: phase)
        case .connected:
            EmptyView()
        case .reconnecting(let attempt, let retryAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(retryAt.timeIntervalSince(context.date).rounded(.up)))
                Banner(
                    .warning,
                    headline: seconds > 0 ? "Connection lost. Reconnecting in \(seconds)s (attempt \(attempt))" : "Reconnecting… (attempt \(attempt))",
                    actions: [.init("Now") { coordinator.reconnect(tab) }, .init("Close") { coordinator.close(tab) }]
                )
            }
        case .disconnected(let reason):
            disconnectedBanner(reason)
        }
    }

    private func connecting(phase: ConnectPhase?) -> some View {
        VStack(spacing: TildeSpacing.m) {
            ProgressView().controlSize(.regular).tint(TildeColor.accent)
            Text("Connecting to \(tab.server.target.username)@\(tab.server.target.host):\(String(tab.server.target.port)) …")
                .tildeMono(13, weight: .medium, relativeTo: .footnote)
                .foregroundStyle(TildeColor.text)
                .multilineTextAlignment(.center)
            if let phase {
                Text(phase.title).tildeMono(11, relativeTo: .caption).foregroundStyle(TildeColor.text3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 120)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connecting to \(tab.server.name)")
    }

    @ViewBuilder
    private func disconnectedBanner(_ reason: SessionEndReason) -> some View {
        switch reason {
        case .exited(let status):
            Banner(.info, headline: status.map { "Session ended (exit \($0))" } ?? "Session ended",
                   actions: [.init("Reconnect") { coordinator.reconnect(tab) }, .init("Close tab") { coordinator.close(tab) }])
        case .userClosed:
            Banner(.info, headline: "Disconnected",
                   actions: [.init("Reconnect") { coordinator.reconnect(tab) }, .init("Close tab") { coordinator.close(tab) }])
        case .error(let error):
            let copy = SessionErrorCopy.present(error, server: tab.server)
            Banner(.error, headline: copy.headline, detail: copy.detail,
                   actions: copy.actions.map { action in Banner.Action(action.title) { handle(action) } })
        }
    }
}

#Preview("Session: connected") {
    SessionPreviewHost(failure: nil)
}

#Preview("Session: refused") {
    SessionPreviewHost(failure: .refused)
}

#Preview("Session: auth failed") {
    SessionPreviewHost(failure: .authFailed(method: "publickey", serverAllows: ["publickey"]))
}

private struct SessionPreviewHost: View {
    let failure: SessionError?
    var body: some View {
        TildePreviewHost(sessionFailure: failure) { navigator in
            if let tab = navigator.selectedTab { SessionScreen(tab: tab) } else { Color.clear }
        }
    }
}
