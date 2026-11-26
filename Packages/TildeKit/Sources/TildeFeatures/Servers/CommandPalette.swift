import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// One row of the command palette.
struct PaletteItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case quickConnect(QuickConnectResult)
        case server(UUID)
        case session(UUID)
        case snippet(SnippetSnapshot)
        case action(PaletteAction)
    }

    enum Section: Int, CaseIterable {
        case connect, sessions, servers, snippets, actions

        var title: String {
            switch self {
            case .connect: "Connect"
            case .sessions: "Sessions"
            case .servers: "Servers"
            case .snippets: "Snippets"
            case .actions: "Actions"
            }
        }
    }

    var id: String
    var kind: Kind
    var section: Section
    var title: String
    var subtitle: String?
    var symbol: String
    var environment: ServerEnvironment = .none
    var isMono = false
    /// The keyboard shortcut shown at the right edge of the row on the Mac (`⌥⌘K`), if the item has one.
    var shortcut: String?
}

enum PaletteAction: String, CaseIterable, Equatable {
    case newServer, settings, keys, snippets, generateKey, importConfig, reopenClosed

    var title: String {
        switch self {
        case .newServer: "New Server…"
        case .settings: "Settings"
        case .keys: "Keys"
        case .snippets: "Snippets"
        case .generateKey: "Generate SSH Key…"
        case .importConfig: "Import ssh config…"
        case .reopenClosed: "Reopen Closed Session"
        }
    }

    var symbol: String {
        switch self {
        case .newServer: "server.rack"
        case .settings: "gearshape"
        case .keys: "key"
        case .snippets: "bolt"
        case .generateKey: "key.fill"
        case .importConfig: "square.and.arrow.down"
        case .reopenClosed: "arrow.uturn.backward"
        }
    }
}

/// The shortcuts the Mac palette shows in its right-hand column, and the hints in its footer. Pure, so it is unit tested.
enum PaletteShortcut {
    /// The menu shortcut of an action, as the menu bar shows it.
    static func label(for action: PaletteAction) -> String? {
        switch action {
        case .newServer: "⇧⌘N"
        case .settings: "⌘,"
        case .keys: "⌥⌘K"
        case .snippets: "⌥⌘S"
        case .reopenClosed: "⇧⌘T"
        case .generateKey, .importConfig: nil
        }
    }

    /// The ⌘1...⌘9 shortcut of the tab at `index`, by the same rule as the Window menu: ⌘9 is always the last tab, so
    /// with more than nine tabs the ninth has none.
    static func label(forTabAt index: Int, tabCount: Int) -> String? {
        (1...9).first { TabShortcut.index(forDigit: $0, tabCount: tabCount) == index }.map { "⌘\($0)" }
    }

    /// One footer hint: the keys and what they do.
    struct Hint: Equatable {
        var keys: String
        var title: String
    }

    /// The footer hints for the highlighted row: Return does what the row does, ⌘Return opens a server in a new tab
    /// (only on a server row), Esc closes.
    static func hints(for item: PaletteItem?) -> [Hint] {
        var hints: [Hint] = []
        switch item?.kind {
        case .quickConnect, .server: hints.append(Hint(keys: "↵", title: "connect"))
        case .session: hints.append(Hint(keys: "↵", title: "switch"))
        case .snippet: hints.append(Hint(keys: "↵", title: "insert"))
        case .action: hints.append(Hint(keys: "↵", title: "run"))
        case nil: break
        }
        if case .server = item?.kind { hints.append(Hint(keys: "⌘↵", title: "new tab")) }
        hints.append(Hint(keys: "esc", title: "close"))
        return hints
    }
}

/// Ranks palette candidates for a query (pure, so it is unit-tested). Sections keep a fixed order; inside a section
/// the best fuzzy match comes first.
enum PaletteRanking {
    static func rank(_ candidates: [PaletteItem], query: String) -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var scored: [(item: PaletteItem, score: Int, order: Int)] = []
        for (order, item) in candidates.enumerated() {
            // Quick Connect rows come from the parser, not from fuzzy matching.
            if case .quickConnect = item.kind {
                scored.append((item, Int.max, order))
                continue
            }
            let haystack = [item.title, item.subtitle ?? ""].joined(separator: " ")
            guard let score = Fuzzy.score(q, in: haystack) else { continue }
            let titleBonus = Fuzzy.score(q, in: item.title) != nil ? 100 : 0
            scored.append((item, score + titleBonus, order))
        }
        return scored.sorted { a, b in
            if a.item.section != b.item.section { return a.item.section.rawValue < b.item.section.rawValue }
            if q.isEmpty { return a.order < b.order }
            return a.score != b.score ? a.score > b.score : a.order < b.order
        }.map(\.item)
    }
}

/// The command palette (Cmd-P; long-press the tab count on iPhone): fuzzy jump to a server, session, snippet or action.
/// Return runs the first (or highlighted) row; typing a target like `deploy@10.0.4.12:2222` offers Connect.
struct CommandPalette: View {
    let mode: PaletteMode

    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Server.name) private var servers: [Server]
    @Query(sort: \RecentConnection.lastUsedAt, order: .reverse) private var recents: [RecentConnection]

    @State private var query = ""
    @State private var highlighted: String?
    @State private var snippets: [SnippetSnapshot] = []
    @State private var pendingFill: SnippetSnapshot?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        panel
        .task(id: query) {
            guard mode != .newTab else { return }
            snippets = await services.snippets.snippets(matching: query)
        }
        .onAppear { fieldFocused = true }
        .sheet(item: $pendingFill) { snippet in
            SnippetFillSheet(snippet: snippet) { values in
                coordinator.insert(snippet, values: values, in: navigator.windowID)
                pendingFill = nil
                dismiss()
            }
        }
    }

    @ViewBuilder private var panel: some View {
        #if os(macOS)
        // A floating glass panel: the field, the results with their shortcut column, and a row of key hints.
        VStack(spacing: 0) {
            field
            Divider().overlay(TildeColor.border)
            resultList
            Divider().overlay(TildeColor.border)
            footer
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 380, idealHeight: 480, maxHeight: TildeSheetMetrics.macMaxHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .tint(TildeColor.accent)
        .presentationSizing(.fitted)
        #else
        TildeSheet(title, scrolls: false, idealHeight: 560) {
            VStack(spacing: 0) {
                field
                Divider().overlay(TildeColor.border)
                resultList
            }
        } actions: {
            TildeCancelButton { dismiss() }
        }
        #endif
    }

    #if os(macOS)
    /// ↵ connect · ⌘↵ new tab · esc close, following the highlighted row.
    private var footer: some View {
        HStack(spacing: TildeSpacing.l) {
            ForEach(PaletteShortcut.hints(for: highlightedItem ?? items.first), id: \.keys) { hint in
                HStack(spacing: 6) {
                    Text(hint.keys)
                        .font(TildeFont.mono(11, weight: .semibold))
                        .foregroundStyle(TildeColor.text2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TildeColor.surface2, in: RoundedRectangle(cornerRadius: 5))
                    Text(hint.title).font(TildeFont.caption).foregroundStyle(TildeColor.text3)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TildeSheetMetrics.padding)
        .frame(minHeight: 36)
    }
    #endif

    private var title: String {
        switch mode {
        case .all: "Command Palette"
        case .newTab: "New Tab"
        case .snippets: "Snippets"
        }
    }

    private var launcher: QuickConnectLauncher { QuickConnectLauncher(services: services, context: context, navigator: navigator) }

    // MARK: UI

    private var field: some View {
        HStack(spacing: TildeSpacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(TildeColor.text3).accessibilityHidden(true)
            TextField("", text: $query, prompt: Text(mode == .snippets ? "Search snippets" : "Search, or user@host:port").foregroundStyle(TildeColor.text3))
                .textFieldStyle(.plain)
                .tildeMono(16)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($fieldFocused)
                .submitLabel(.go)
                .onSubmit { run(highlightedItem ?? items.first) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
                #if os(macOS)
                // ⌘↵ opens the highlighted server in a new tab. Plain ↵ is left to `onSubmit` above.
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    openInNewTab(highlightedItem ?? items.first)
                    return .handled
                }
                #endif
                .accessibilityLabel(mode == .snippets ? "Search snippets" : "Search")
        }
        .padding(.horizontal, TildeSheetMetrics.padding)
        .frame(minHeight: 52)
        #if !os(macOS)
        .background(TildeColor.surface)
        #endif
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(PaletteItem.Section.allCases, id: \.self) { section in
                        let rows = items.filter { $0.section == section }
                        if !rows.isEmpty {
                            SectionHeader(section.title)
                                .padding(.horizontal, TildeSheetMetrics.padding)
                                .padding(.top, TildeSpacing.l)
                                .padding(.bottom, TildeSpacing.xs)
                            ForEach(rows) { item in
                                let isOn = item.id == (highlighted ?? items.first?.id)
                                Button { run(item) } label: { PaletteRow(item: item, isHighlighted: isOn) }
                                    .buttonStyle(.plain)
                                    .background(isOn ? TildeColor.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                    .padding(.horizontal, TildeSpacing.s)
                                    .id(item.id)
                            }
                        }
                    }
                    if items.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "magnifyingglass", description: Text(emptyMessage))
                            .frame(maxWidth: .infinity)
                            .padding(.top, TildeSpacing.xxl)
                    }
                }
                .padding(.bottom, TildeSpacing.l)
            }
            #if !os(macOS)
            .background(TildeColor.bg)
            #endif
            .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
            .onChange(of: query) { highlighted = nil }
        }
    }

    private var emptyTitle: String { mode == .snippets ? "No snippets" : "No matches" }
    private var emptyMessage: String {
        mode == .snippets ? "Add snippets from the Snippets list." : "Try a different search, or type user@host to connect."
    }

    // MARK: Items

    private var items: [PaletteItem] { PaletteRanking.rank(candidates, query: query) }
    private var highlightedItem: PaletteItem? { items.first { $0.id == highlighted } }

    private var candidates: [PaletteItem] {
        var result: [PaletteItem] = []
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if mode != .snippets, !trimmed.isEmpty, let parsed = launcher.parse(trimmed) {
            result.append(PaletteItem(id: "qc", kind: .quickConnect(parsed), section: .connect, title: "Connect to \(parsed.target.displayString)",
                                      subtitle: nil, symbol: "return", isMono: true))
        }
        if mode != .snippets {
            if mode == .all {
                let tabs = navigator.tabs
                for (index, tab) in tabs.enumerated() {
                    let shortcut = PaletteShortcut.label(forTabAt: index, tabCount: tabs.count)
                    result.append(PaletteItem(id: "tab-\(tab.id)", kind: .session(tab.id), section: .sessions, title: tab.title,
                                              subtitle: tab.server.target.displayString, symbol: "terminal", environment: tab.environment, isMono: true,
                                              shortcut: shortcut))
                }
            }
            for server in servers {
                result.append(PaletteItem(id: "srv-\(server.id)", kind: .server(server.id), section: .servers, title: ServerMapper.displayName(server),
                                          subtitle: "\(server.username)@\(server.host)" + (server.port == 22 ? "" : ":\(server.port)"),
                                          symbol: "server.rack", environment: ServerMapper.environment(server), isMono: true))
            }
            if trimmed.isEmpty {
                for recent in recents.prefix(5) {
                    result.append(PaletteItem(id: "recent-\(recent.id)", kind: .quickConnect(recentResult(recent)), section: .connect,
                                              title: recent.target, subtitle: "Recent", symbol: "clock.arrow.circlepath", isMono: true))
                }
            }
        }
        if mode != .newTab {
            for snippet in snippets {
                result.append(PaletteItem(id: "snip-\(snippet.id)", kind: .snippet(snippet), section: .snippets, title: snippet.name,
                                          subtitle: snippet.command, symbol: snippet.runOnInsert ? "return" : "bolt", isMono: false))
            }
        }
        if mode == .all {
            for action in PaletteAction.allCases where action != .reopenClosed || !coordinator.recentlyClosed.isEmpty {
                result.append(PaletteItem(id: "act-\(action.rawValue)", kind: .action(action), section: .actions, title: action.title,
                                          subtitle: nil, symbol: action.symbol, shortcut: PaletteShortcut.label(for: action)))
            }
        }
        return result
    }

    private func recentResult(_ recent: RecentConnection) -> QuickConnectResult {
        launcher.parse(recent.target) ?? QuickConnectResult(target: ConnectionTarget(host: recent.target, username: TildeSettings.currentDefaultUser))
    }

    private func move(_ delta: Int) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(of: highlighted ?? ids[0]) ?? 0
        highlighted = ids[min(max(current + delta, 0), ids.count - 1)]
    }

    // MARK: Run

    private func run(_ item: PaletteItem?) {
        guard let item else { return }
        switch item.kind {
        case .quickConnect(let result):
            dismiss()
            launcher.connect(result)
        case .server(let id):
            guard let server = servers.first(where: { $0.id == id }) else { return }
            dismiss()
            launcher.open(server, newSession: mode == .newTab && coordinator.isLive(serverID: id))
        case .session(let id):
            dismiss()
            if let tab = coordinator.tab(id: id) { coordinator.select(tab); navigator.showDeckIfCompact() }
        case .snippet(let snippet):
            if SnippetTemplate.placeholders(in: snippet.command).isEmpty {
                dismiss()
                coordinator.insert(snippet, in: navigator.windowID)
            } else {
                pendingFill = snippet
            }
        case .action(let action):
            perform(action)
        }
    }

    #if os(macOS)
    /// ⌘↵: a server opens in a new tab even if it is already open; any other row does what ↵ does.
    private func openInNewTab(_ item: PaletteItem?) {
        guard let item else { return }
        guard case .server(let id) = item.kind, let server = servers.first(where: { $0.id == id }) else {
            run(item)
            return
        }
        dismiss()
        launcher.open(server, newSession: true)
    }
    #endif

    private func perform(_ action: PaletteAction) {
        switch action {
        case .newServer: navigator.present(.newServer)
        case .settings: navigator.present(.settings)
        case .keys: navigator.present(.keys)
        case .snippets: navigator.present(.snippets)
        case .generateKey: navigator.present(.generateKey)
        case .importConfig: navigator.present(.importSSHConfig)
        case .reopenClosed:
            dismiss()
            navigator.reopenLastClosed()
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: TildeSpacing.m) {
            Image(systemName: item.symbol)
                .font(.system(size: 14))
                .foregroundStyle(isHighlighted ? TildeColor.accent : TildeColor.text3)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(item.isMono ? TildeFont.mono(14, weight: .semibold) : .system(size: 15, weight: .medium))
                    .foregroundStyle(item.section == .connect ? TildeColor.accent : TildeColor.text)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(TildeFont.mono(11)).foregroundStyle(TildeColor.text2).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            EnvBadge(EnvTone(item.environment))
            #if os(macOS)
            // A fixed, right-aligned column, so the shortcuts line up whatever the row holds.
            Text(item.shortcut ?? "")
                .font(TildeFont.mono(12))
                .foregroundStyle(TildeColor.text3)
                .frame(width: 56, alignment: .trailing)
                .accessibilityLabel(item.shortcut.map { "Shortcut \($0)" } ?? "")
            #else
            if isHighlighted { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(TildeColor.text3).accessibilityHidden(true) }
            #endif
        }
        .padding(.horizontal, TildeSpacing.m)
        .padding(.vertical, 6)
        .frame(minHeight: TildeSheetMetrics.rowHeight + 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Command palette") {
    TildePreviewHost { _ in CommandPalette(mode: .all) }
}
