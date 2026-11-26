#if os(macOS)
import SwiftUI
import TildeCore
import TildeDesign

/// The Mac tab strip (design A, "Flat Mac tabs"): full width and flat, tabs share the width equally down to a
/// minimum and then the strip scrolls. Each tab has a 2 pt environment stripe on top, a faint red wash when it is PROD,
/// its `⌘` number at the right, and a close button that replaces the state dot at the LEFT while the pointer is over
/// it. The selected tab is the "front" one: brighter fill, full-strength stripe, no hairline under it. iPad keeps the
/// rounded `TabStrip` look.
struct MacTabStrip: View {
    let tabs: [SessionTab]
    let selectedID: UUID?
    @Environment(AppNavigator.self) private var navigator

    private enum Metrics {
        static let height: CGFloat = TildeSpacing.tabBarHeight
        static let minTabWidth: CGFloat = 120
        static let newTabWidth: CGFloat = 34
    }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                let count = max(tabs.count, 1)
                let tabWidth = max(Metrics.minTabWidth, proxy.size.width / CGFloat(count))
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                MacTabItem(tab: tab, index: index + 1, tabCount: tabs.count, isSelected: tab.id == selectedID)
                                    .frame(width: tabWidth)
                                    .id(tab.id)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // The strip is not content under the toolbar: no blur plate over the title bar.
                    .scrollEdgeEffectHidden(true, for: .all)
                    .onChange(of: selectedID, initial: true) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Button { navigator.present(.palette(.newTab)) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TildeColor.text2)
                    .frame(width: Metrics.newTabWidth, height: Metrics.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New tab")
            .help("New tab (⌘T)")
            .overlay(alignment: .bottom) { hairline }
        }
        .frame(height: Metrics.height)
        // Not under the toolbar: a plain `background` would also paint into the top safe area.
        .background(TildeColor.surface, ignoresSafeAreaEdges: [])
    }

    private var hairline: some View {
        Rectangle().fill(TildeColor.border).frame(height: TildeSpacing.hairline)
    }
}

private struct MacTabItem: View {
    let tab: SessionTab
    let index: Int
    let tabCount: Int
    let isSelected: Bool
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    private var tone: EnvTone { tab.tone }
    private var isWaitingForHostKey: Bool { coordinator.pendingInTabHostKey(for: tab.id) != nil }

    var body: some View {
        HStack(spacing: 7) {
            leadingSlot
            Text(tab.title)
                .tildeMono(12, weight: isSelected ? .semibold : .medium, relativeTo: .footnote)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let digit = TabStripHint.digit(forTab: index, of: tabCount) {
                Text("⌘\(digit)")
                    .tildeMono(10, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(TildeColor.text3)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .foregroundStyle(isSelected || isHovered ? TildeColor.text : TildeColor.text2)
        .background { fill }
        // The environment stripe on every tab, so PROD stays visible whatever the dot is showing.
        .overlay(alignment: .top) { EnvStripe(tone).opacity(isSelected ? 1 : 0.55).allowsHitTesting(false) }
        // Hairlines: between tabs, and under every tab except the selected one, which opens into the terminal.
        .overlay(alignment: .trailing) { Rectangle().fill(TildeColor.border).frame(width: TildeSpacing.hairline) }
        .overlay(alignment: .bottom) {
            if !isSelected { Rectangle().fill(TildeColor.border).frame(height: TildeSpacing.hairline) }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { coordinator.select(tab) }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .contextMenu {
            SessionMenuItems(tab: tab)
            Button {
                let id = coordinator.moveToOwnWindow(tab)
                openWindow(id: "session", value: SessionWindowValue(sessionID: id))
            } label: { Label("Open in New Window", systemImage: "macwindow.badge.plus") }
        }
        .help(tab.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { coordinator.select(tab) }
        .accessibilityAction(named: "Close tab") { coordinator.close(tab) }
    }

    /// The state dot, or the close button while hovered.
    @ViewBuilder
    private var leadingSlot: some View {
        ZStack {
            MacTabIndicator(tab: tab, isWaitingForHostKey: isWaitingForHostKey)
                .opacity(isHovered ? 0 : 1)
            Button { coordinator.close(tab) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TildeColor.text2)
                    .frame(width: 16, height: 16)
                    .background(TildeColor.surface3.opacity(0.9), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(true)
            .help("Close tab (⌘W)")
        }
        .frame(width: 16, height: 16)
    }

    /// Neutral fill, brighter for the selected (front) tab, with a faint red wash on PROD.
    private var fill: some View {
        ZStack {
            if isSelected {
                TildeColor.surface3
            } else if isHovered {
                TildeColor.surface2
            }
            if tone == .prod { tone.color.opacity(isSelected ? 0.12 : 0.06) }
        }
    }

    private var accessibilityLabel: String {
        var label = "Tab \(index), \(tab.title)"
        if tone != .none { label += ", \(tone.accessibilityName)" }
        if isWaitingForHostKey { label += ", waiting for host key verification" }
        return label
    }
}

/// The dot at the start of a tab: the environment colour while the session is healthy, a spinner while it connects
/// or reconnects, an alert glyph when it is gone, and a key glyph while it waits for a host-key answer.
private struct MacTabIndicator: View {
    let tab: SessionTab
    let isWaitingForHostKey: Bool

    var body: some View {
        Group {
            if isWaitingForHostKey {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(TildeColor.warn)
            } else {
                switch tab.state {
                case .idle, .connecting:
                    ProgressView().controlSize(.mini).tint(TildeColor.accent)
                case .reconnecting:
                    ProgressView().controlSize(.mini).tint(TildeColor.warn)
                case .disconnected(let reason):
                    if case .error = reason {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(TildeColor.danger)
                    } else {
                        Image(systemName: "circle").foregroundStyle(TildeColor.text3)
                    }
                case .connected:
                    Circle()
                        .fill(tab.tone == .none ? TildeColor.accent : tab.tone.color)
                        .frame(width: 7, height: 7)
                }
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}
#endif
