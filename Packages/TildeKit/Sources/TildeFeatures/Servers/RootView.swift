import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// The app's root (design section 3): an iPhone `TabView` (Servers, Keys, Snippets, Settings) with the session
/// deck and the live-session accessory, or an iPad / Mac `NavigationSplitView` with the server list as the sidebar
/// and the tab strip + terminal as the detail.
///
/// Requires `SessionCoordinator` in the environment (see `TildeApp`).
public struct RootView: View {
    public init() {}

    public var body: some View {
        WindowHost {
            RootLayout()
        }
        .background(TildeColor.bg)
        .tint(TildeColor.accent)
    }
}

private struct RootLayout: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        #if os(macOS)
        SplitRoot()
        #else
        if sizeClass == .compact { PhoneRoot() } else { SplitRoot() }
        #endif
    }
}

// MARK: - iPhone

#if os(iOS)
private struct PhoneRoot: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        TabView(selection: $navigator.phoneTab) {
            Tab("Servers", systemImage: "server.rack", value: PhoneTab.servers) {
                NavigationStack { ServerList() }
            }
            Tab("Keys", systemImage: "key", value: PhoneTab.keys) {
                NavigationStack { KeyListView() }
            }
            Tab("Snippets", systemImage: "bolt", value: PhoneTab.snippets) {
                NavigationStack { SnippetList() }
            }
            Tab("Settings", systemImage: "gearshape", value: PhoneTab.settings) {
                SettingsRoot()
            }
        }
        .modifier(LiveSessionsAccessory(isEnabled: !navigator.tabs.isEmpty))
        .fullScreenCover(isPresented: $navigator.isDeckPresented) {
            // The deck covers the window, so it hosts the window's sheets and prompts while it is up.
            SessionDeck()
                .modifier(SessionPromptHost(suppressed: navigator.sheet != nil))
                .modifier(AppSheetHost(isActive: true))
                .background(TildeColor.bg)
        }
        .onAppear { navigator.isCompact = true }
        .onDisappear { navigator.isCompact = false; navigator.isDeckPresented = false }
    }
}

/// Shows the live pill above the tab bar while sessions exist. `isEnabled:` needs iOS 26.1; on 26.0 the accessory is
/// always there and reads "No live sessions" when empty.
private struct LiveSessionsAccessory: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: isEnabled) { LiveSessionsPill() }
        } else {
            content.tabViewBottomAccessory { LiveSessionsPill() }
        }
    }
}

/// `● 3 live · prod-api-01 ›`: brings the session deck back (iOS 26 `tabViewBottomAccessory`).
private struct LiveSessionsPill: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        let hasTabs = !navigator.tabs.isEmpty
        let live = navigator.tabs.filter(\.isLive).count
        let selected = navigator.selectedTab
        Button { if hasTabs { navigator.isDeckPresented = true } } label: {
            HStack(spacing: 8) {
                StatusDot(hasTabs ? .live : .unknown)
                Text(hasTabs ? "\(live) live" : "No live sessions").tildeMono(12, weight: .semibold, relativeTo: .caption)
                if let selected {
                    Text("· \(selected.title)").tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.text2).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(TildeColor.text3)
            }
            .padding(.horizontal, TildeSpacing.l)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(live) live \(live == 1 ? "session" : "sessions")")
        .accessibilityHint("Opens the session view")
    }
}
#endif

// MARK: - iPad and Mac

private struct SplitRoot: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView(columnVisibility: $navigator.columnVisibility) {
            ServerList()
                .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
        } detail: {
            SessionContainer()
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear { navigator.isCompact = false; navigator.isDeckPresented = false }
    }
}

/// Keys · Snippets · Settings at the foot of the sidebar (design section 3.3).
private struct SidebarFooter: View {
    @Environment(AppNavigator.self) private var navigator
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        HStack(spacing: TildeSpacing.l) {
            footerButton("Keys", systemImage: "key") { navigator.present(.keys) }
            footerButton("Snippets", systemImage: "bolt") { navigator.present(.snippets) }
            footerButton("Settings", systemImage: "gearshape") {
                #if os(macOS)
                openSettings()
                #else
                navigator.present(.settings)
                #endif
            }
            Spacer()
        }
        .padding(.horizontal, TildeSpacing.l)
        .padding(.vertical, TildeSpacing.s)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(TildeColor.border).frame(height: TildeSpacing.hairline) }
    }

    private func footerButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly).font(.system(size: 15)).frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(TildeColor.text2)
        .accessibilityLabel(title)
        .help(title)
    }
}

#Preview("Root: phone") {
    TildePreviewHost(openSession: false) { _ in RootView() }
}

#Preview("Root: split", traits: .landscapeLeft) {
    TildePreviewHost { _ in RootView() }
}
