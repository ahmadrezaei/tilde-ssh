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
        NavigationStack {
            VStack(spacing: 0) {
                field
                Divider().overlay(TildeColor.border)
                resultList
            }
            .background(TildeColor.bg)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
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
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

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
            Image(systemName: "magnifyingglass").foregroundStyle(TildeColor.text3)
            TextField(mode == .snippets ? "Search snippets" : "Search, or user@host:port", text: $query)
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
        }
        .padding(.horizontal, TildeSpacing.l)
        .padding(.vertical, TildeSpacing.m)
        .background(TildeColor.surface)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(PaletteItem.Section.allCases, id: \.self) { section in
                    let rows = items.filter { $0.section == section }
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { item in
                                Button { run(item) } label: { PaletteRow(item: item, isHighlighted: item.id == (highlighted ?? items.first?.id)) }
                                    .buttonStyle(.plain)
                                    .listRowBackground(item.id == (highlighted ?? items.first?.id) ? TildeColor.accentSoft : TildeColor.surface)
                                    .id(item.id)
                            }
                        } header: {
                            SectionHeader(section.title)
                        }
                    }
                }
                if items.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "magnifyingglass", description: Text(emptyMessage))
                        .listRowBackground(Color.clear)
                }
            }
            .tildeList()
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
                for tab in navigator.tabs {
                    result.append(PaletteItem(id: "tab-\(tab.id)", kind: .session(tab.id), section: .sessions, title: tab.title,
                                              subtitle: tab.server.target.displayString, symbol: "terminal", environment: tab.environment, isMono: true))
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
                                          subtitle: nil, symbol: action.symbol))
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

    private func perform(_ action: PaletteAction) {
        switch action {
        case .newServer: navigator.sheet = .newServer
        case .settings: navigator.sheet = .settings
        case .keys: navigator.sheet = .keys
        case .snippets: navigator.sheet = .snippets
        case .generateKey: navigator.sheet = .generateKey
        case .importConfig: navigator.sheet = .importSSHConfig
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
            if isHighlighted { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(TildeColor.text3).accessibilityHidden(true) }
        }
        .tildeRowHeight()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Command palette") {
    TildePreviewHost { _ in CommandPalette(mode: .all) }
}
