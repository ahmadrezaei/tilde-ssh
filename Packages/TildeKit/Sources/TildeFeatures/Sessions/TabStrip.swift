import SwiftUI
import TildeCore
import TildeDesign

/// The in-window tab strip (design sections 3.3 and 3.4): rounded tabs with an environment dot, the server name in
/// mono, a close button (on hover on the Mac, always on iPad), an accent edge under the selected tab, and a `+` after
/// the last one. Tabs share the width equally between a minimum and a maximum; past the minimum the strip scrolls and
/// keeps the selected tab in view.
struct TabStrip: View {
    let tabs: [SessionTab]
    let selectedID: UUID?
    @Environment(AppNavigator.self) private var navigator

    private enum Metrics {
        #if os(macOS)
        static let stripHeight: CGFloat = 36
        static let tabHeight: CGFloat = 28
        static let minTabWidth: CGFloat = 132
        #else
        static let stripHeight: CGFloat = 44
        static let tabHeight: CGFloat = 34
        static let minTabWidth: CGFloat = 148
        #endif
        static let maxTabWidth: CGFloat = 208
        static let gap: CGFloat = 4
        static let edge: CGFloat = 8
        static let newTabSize: CGFloat = tabHeight
    }

    var body: some View {
        GeometryReader { proxy in
            let count = max(tabs.count, 1)
            let area = max(proxy.size.width - 2 * Metrics.edge - Metrics.newTabSize - Metrics.gap, Metrics.minTabWidth)
            let fair = (area - Metrics.gap * CGFloat(count - 1)) / CGFloat(count)
            let tabWidth = min(max(fair, Metrics.minTabWidth), Metrics.maxTabWidth)
            let contentWidth = tabWidth * CGFloat(count) + Metrics.gap * CGFloat(count - 1)
            HStack(spacing: Metrics.gap) {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Metrics.gap) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                TabStripItem(tab: tab, index: index + 1, isSelected: tab.id == selectedID, showsHint: tabWidth >= 168)
                                    .frame(width: tabWidth)
                                    .id(tab.id)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // The strip is not content under the toolbar: no blur plate over the title bar.
                    .scrollEdgeEffectHidden(true, for: .all)
                    .frame(width: min(contentWidth, area))
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(id, anchor: .center) }
                    }
                }
                NewTabButton { navigator.present(.palette(.newTab)) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.edge)
            .frame(maxHeight: .infinity)
        }
        .frame(height: Metrics.stripHeight)
        // Not under the toolbar: a plain `background` would also paint into the top safe area.
        .background(TildeColor.surface, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(TildeColor.border).frame(height: TildeSpacing.hairline) }
    }
}

private struct NewTabButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovered ? TildeColor.text : TildeColor.text2)
                .frame(width: 28, height: 28)
                .background(isHovered ? TildeColor.surface3 : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("New tab")
        .help("New tab (⌘T)")
    }
}

private struct TabStripItem: View {
    let tab: SessionTab
    let index: Int
    let isSelected: Bool
    /// Room for the `⌘1` hint on the Mac (it goes first when tabs get narrow).
    let showsHint: Bool
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var isHovered = false

    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    private var tone: EnvTone { tab.tone }
    private var edgeColor: Color { tone == .none ? TildeColor.accent : tone.color }

    private var closeIsVisible: Bool {
        #if os(macOS)
        isHovered || isSelected
        #else
        true
        #endif
    }

    var body: some View {
        HStack(spacing: 7) {
            TabIndicator(tab: tab)
            Text(tab.title)
                .tildeMono(12, weight: isSelected ? .semibold : .medium, relativeTo: .footnote)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailingAccessory
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(maxHeight: .infinity)
        .foregroundStyle(isSelected || isHovered ? TildeColor.text : TildeColor.text2)
        .background { shape.fill(fill) }
        .overlay { shape.strokeBorder(stroke, lineWidth: 1) }
        .overlay(alignment: .bottom) {
            if isSelected {
                Capsule().fill(edgeColor).frame(height: 2).padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 4)
        .contentShape(shape)
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
        .accessibilityLabel("Tab \(index), \(tab.title)\(tone == .none ? "" : ", \(tone.accessibilityName)")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Close tab") { coordinator.close(tab) }
    }

    /// The close button, or on the Mac a `⌘1` hint in its place while the tab is idle.
    private var trailingAccessory: some View {
        ZStack {
            Button { coordinator.close(tab) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(TildeColor.text2)
                    .frame(width: 20, height: 20)
                    .background(isHovered ? TildeColor.surface3.opacity(0.9) : .clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(closeIsVisible ? 1 : 0)
            .allowsHitTesting(closeIsVisible)
            .accessibilityHidden(true)
            .help("Close tab (⌘W)")
            #if os(macOS)
            if !closeIsVisible, showsHint, index <= 9 {
                Text("⌘\(index)")
                    .tildeMono(10, weight: .medium, relativeTo: .caption2)
                    .foregroundStyle(TildeColor.text3)
                    .allowsHitTesting(false)
            }
            #endif
        }
        .frame(minWidth: 20)
    }

    private var fill: Color {
        if isSelected {
            return tone == .prod ? tone.color.opacity(0.14) : TildeColor.surface3
        }
        return isHovered ? TildeColor.surface2 : .clear
    }

    private var stroke: Color {
        if isSelected { return tone == .prod ? tone.color.opacity(0.38) : TildeColor.border }
        return .clear
    }
}

/// The dot at the start of a tab: the environment colour while the session is healthy, a spinner while it connects
/// or reconnects, and an alert glyph when it is gone.
private struct TabIndicator: View {
    let tab: SessionTab

    var body: some View {
        Group {
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
                    .shadow(color: (tab.tone == .none ? TildeColor.accent : tab.tone.color).opacity(0.5), radius: 2.5)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}
