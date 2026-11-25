import SwiftUI
import TildeCore
import TildeDesign

/// iPhone: the full-screen session deck, presented over everything. Closing it (chevron) keeps sessions alive;
/// the live pill on the tab bar brings it back.
struct SessionDeck: View {
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator
    @State private var showsGrid = false

    var body: some View {
        let tabs = navigator.tabs
        let selected = navigator.selectedTab
        VStack(spacing: 0) {
            if let selected {
                SessionTitleBar(
                    tab: selected,
                    tabCount: tabs.count,
                    onClose: { coordinator.isDeckPresented = false },
                    onShowGrid: { showsGrid = true },
                    onShowPalette: { navigator.present(.palette(.all)) }
                )
            }
            ZStack {
                SessionStack(tabs: tabs, selectedID: selected?.id)
                if selected == nil {
                    EmptyState("No open sessions", message: "Connect to a server to start one.") {
                        Button("Close") { coordinator.isDeckPresented = false }.buttonStyle(.tildeSecondary)
                    }
                }
            }
        }
        .background(TildeColor.bg)
        .sheet(isPresented: $showsGrid) {
            SessionGrid(onDismiss: { showsGrid = false })
                .presentationDetents([.medium, .large])
        }
        .onChange(of: tabs.isEmpty) { _, isEmpty in
            if isEmpty { coordinator.isDeckPresented = false }
        }
    }
}

/// The 36 pt title bar (design section 4.5): env stripe on top, back chevron, title and status, tab count, `…` menu.
struct SessionTitleBar: View {
    let tab: SessionTab
    let tabCount: Int
    let onClose: () -> Void
    let onShowGrid: () -> Void
    let onShowPalette: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EnvStripe(tab.tone)
            HStack(spacing: TildeSpacing.s) {
                Button(action: onClose) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .foregroundStyle(TildeColor.accent)
                .accessibilityLabel("Close session view")
                .accessibilityHint("Sessions stay connected")

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(tab.title).tildeMono(13, weight: .bold, relativeTo: .subheadline).lineLimit(1)
                        EnvBadge(tab.tone)
                    }
                    statusLine
                }
                Spacer(minLength: 0)

                TabCountButton(count: tabCount, onTap: onShowGrid, onLongPress: onShowPalette)

                Menu { SessionMenuItems(tab: tab) } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(TildeColor.text2)
                .accessibilityLabel("Session menu")
            }
            .padding(.horizontal, TildeSpacing.s)
            .frame(minHeight: TildeSpacing.titleBarHeight)
        }
        .foregroundStyle(TildeColor.text)
        .background(TildeColor.surface.opacity(0.85))
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(TildeColor.border).frame(height: TildeSpacing.hairline) }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch tab.state {
        case .connected:
            LatencyLabel(milliseconds: tab.latencyMilliseconds, kind: tab.latencyMilliseconds == nil ? .live : nil)
        case .connecting, .idle:
            Text("connecting…").tildeMono(10, relativeTo: .caption2).foregroundStyle(TildeColor.text2)
        case .reconnecting:
            Text("reconnecting…").tildeMono(10, relativeTo: .caption2).foregroundStyle(TildeColor.warn)
        case .disconnected:
            Text("disconnected").tildeMono(10, relativeTo: .caption2).foregroundStyle(TildeColor.text3)
        }
    }
}

/// `[3]`: tap opens the session grid, long-press the command palette.
struct TabCountButton: View {
    let count: Int
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Text("\(count)")
            .tildeMono(11, weight: .bold, relativeTo: .caption)
            .foregroundStyle(TildeColor.text)
            .frame(minWidth: 26, minHeight: 24)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(TildeColor.text2, lineWidth: 1.6))
            .frame(minWidth: 44, minHeight: 36)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.4, perform: onLongPress)
            .accessibilityElement()
            .accessibilityLabel("\(count) \(count == 1 ? "session" : "sessions")")
            .accessibilityHint("Opens the session switcher")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Command palette", onLongPress)
            .accessibilityAction(.default, onTap)
    }
}

// MARK: - Grid switcher

/// A grid of open sessions: tap to switch, x to close, + for a new one.
struct SessionGrid: View {
    let onDismiss: () -> Void
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: TildeSpacing.m)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: TildeSpacing.m) {
                    ForEach(navigator.tabs) { tab in
                        SessionCard(tab: tab, isSelected: tab.id == navigator.selectedTab?.id,
                                    onSelect: { coordinator.select(tab); onDismiss() },
                                    onClose: { coordinator.close(tab) })
                    }
                    Button {
                        onDismiss()
                        navigator.present(.palette(.newTab))
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 22, weight: .semibold))
                            Text("New session").tildeText(12, weight: .semibold, relativeTo: .caption)
                        }
                        .foregroundStyle(TildeColor.accent)
                        .frame(maxWidth: .infinity, minHeight: 92)
                        .overlay(RoundedRectangle(cornerRadius: TildeRadius.card).strokeBorder(TildeColor.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }
                    .buttonStyle(.plain)
                }
                .padding(TildeSpacing.l)
            }
            .background(TildeColor.bg)
            .navigationTitle("Sessions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDismiss) } }
        }
    }
}

private struct SessionCard: View {
    let tab: SessionTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 0) {
                EnvStripe(tab.tone)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        StatusDot(tab.isLive ? .live : tab.statusKind)
                        Text(tab.title).tildeMono(13, weight: .bold, relativeTo: .subheadline).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    Text(tab.server.target.displayString).tildeMono(11, relativeTo: .caption).foregroundStyle(TildeColor.text2).lineLimit(1)
                    HStack {
                        EnvBadge(tab.tone)
                        Spacer()
                        if let ms = tab.latencyMilliseconds {
                            Text("\(ms)ms").tildeMono(10, relativeTo: .caption2).foregroundStyle(TildeColor.text3)
                        }
                    }
                }
                .padding(TildeSpacing.m)
                .frame(minHeight: 82, alignment: .topLeading)
            }
            .foregroundStyle(TildeColor.text)
            .background(TildeColor.surface, in: RoundedRectangle(cornerRadius: TildeRadius.card))
            .clipShape(RoundedRectangle(cornerRadius: TildeRadius.card))
            .overlay(RoundedRectangle(cornerRadius: TildeRadius.card).stroke(isSelected ? TildeColor.accent : TildeColor.border, lineWidth: isSelected ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(TildeColor.text2).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(tab.title)")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tab.title), \(tab.environment == .none ? "" : tab.tone.accessibilityName)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
