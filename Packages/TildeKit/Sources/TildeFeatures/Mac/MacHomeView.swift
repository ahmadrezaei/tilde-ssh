#if os(macOS)
import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// The Mac start page, shown in the detail column while no session is open: a large Quick Connect field, a note about
/// the tab that just closed, the servers you used last, and how each environment is doing.
///
/// It answers "where was I, and is anything wrong?". It needs `SessionCoordinator` and `AppNavigator` in the environment
/// (`WindowHost` provides both) and a SwiftData model context.
public struct MacHomeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    @Query(sort: \Server.name) private var servers: [Server]

    @State private var text = ""
    @State private var selection: UUID?
    @State private var dismissedClosureID: UUID?
    @FocusState private var fieldFocused: Bool

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                quickConnect
                if let closure = visibleClosure { closedBanner(closure) }
                recentSection
                if !summaries.isEmpty { environmentSection }
            }
            .padding(32)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(TildeColor.bg)
        .task(id: homeServers.map { ReachabilityMonitor.key($0.probeTarget) }) {
            for server in homeServers { monitor.refresh(server.probeTarget) }
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: Derived

    private var launcher: QuickConnectLauncher { QuickConnectLauncher(services: services, context: context, navigator: navigator) }
    private var monitor: ReachabilityMonitor { coordinator.reachability }
    private var homeServers: [HomeServer] { servers.map(HomeServer.init) }
    private var recent: [HomeServer] { HomeLogic.recent(homeServers) }

    private var summaries: [EnvironmentSummary] {
        EnvironmentSummary.summaries(homeServers.map { ($0.environment, monitor.status(for: $0.probeTarget)) })
    }

    /// The tab that just closed in this window, while nothing is open and the banner was not dismissed.
    private var visibleClosure: ClosedSession? {
        guard navigator.tabs.isEmpty, let closure = coordinator.lastClosure(in: navigator.windowID),
              closure.id != dismissedClosureID else { return nil }
        return closure
    }

    /// Reopen (and its shortcut, which reopens the newest closure of any window) only applies when that is this one.
    private func canReopen(_ closure: ClosedSession) -> Bool {
        coordinator.recentlyClosed.first?.id == closure.server.id
    }

    /// The saved servers matching the text, best match first (same scoring as the sidebar search).
    private var matches: [Server] {
        let query = ServerQuery(parsing: text)
        return servers
            .compactMap { server in query.score(server.searchItem).map { (server, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ServerMapper.displayName($0.0).localizedStandardCompare(ServerMapper.displayName($1.0)) == .orderedAscending }
            .map(\.0)
    }

    private var submit: HomeLogic.Submit {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return HomeLogic.submit(text: trimmed, parses: launcher.parse(trimmed) != nil, firstMatch: matches.first?.id)
    }

    // MARK: Header and Quick Connect

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Home").tildeText(26, weight: .bold, relativeTo: .largeTitle).foregroundStyle(TildeColor.text)
            Spacer()
            Button { navigator.present(.newServer) } label: { Label("New Server", systemImage: "plus") }
                .controlSize(.large)
        }
    }

    private var quickConnect: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.horizontal").font(.system(size: 18)).foregroundStyle(TildeColor.accent).accessibilityHidden(true)
                TextField("Quick Connect", text: $text, prompt: Text("user@host:port, ssh command, or a server name").foregroundStyle(TildeColor.text3))
                    .textFieldStyle(.plain)
                    .tildeMono(17)
                    .focused($fieldFocused)
                    .autocorrectionDisabled()
                    .onSubmit(connect)
                    .accessibilityLabel("Quick Connect")
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(TildeColor.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(fieldFocused ? TildeColor.accent : TildeColor.border, lineWidth: fieldFocused ? 1.5 : 1))

            Text(submitHint)
                .tildeText(12, relativeTo: .caption)
                .foregroundStyle(TildeColor.text3)
                .frame(height: 16, alignment: .leading)
        }
    }

    private var submitHint: String {
        switch submit {
        case .connect:
            let target = launcher.parse(text.trimmingCharacters(in: .whitespaces))?.target.displayString ?? ""
            return "Return connects to \(target)"
        case .open(let id):
            return "Return opens \(servers.first { $0.id == id }.map(ServerMapper.displayName) ?? "the server")"
        case .nothing:
            return "Return connects. Paste an ssh command, or type part of a saved server's name."
        }
    }

    private func connect() {
        switch submit {
        case .connect:
            launcher.connect(text.trimmingCharacters(in: .whitespaces))
        case .open(let id):
            if let server = servers.first(where: { $0.id == id }) { launcher.open(server) }
        case .nothing:
            return
        }
        text = ""
    }

    // MARK: Banner

    private func closedBanner(_ closure: ClosedSession) -> some View {
        var actions: [Banner.Action] = []
        if canReopen(closure) { actions.append(.init("Reopen  ⇧⌘T") { navigator.reopenLastClosed() }) }
        actions.append(.init("Dismiss") { dismissedClosureID = closure.id })
        return Banner(.info, headline: HomeLogic.message(for: closure), actions: actions)
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Recent")
            if recent.isEmpty {
                Text("Servers you connect to show up here.")
                    .tildeText(13, relativeTo: .body)
                    .foregroundStyle(TildeColor.text3)
                    .padding(.vertical, 8)
            } else {
                // A plain stack, not a `Table`: this page leaves the window the moment a session opens, and tearing
                // down an AppKit-backed table while its rows update ("2 seconds ago", latency) aborts in SwiftUI.
                VStack(spacing: 0) {
                    recentRow(header: true, item: nil)
                    ForEach(recent) { item in recentRow(header: false, item: item) }
                }
                .background(TildeColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TildeColor.border))
            }
        }
    }

    /// One row of Recent (or its header): click selects, double-click or the context menu connects.
    @ViewBuilder
    private func recentRow(header: Bool, item: HomeServer?) -> some View {
        let isSelected = item != nil && item?.id == selection
        HStack(spacing: 12) {
            Group {
                if let item {
                    Text(item.name).tildeMono(13, weight: .semibold).foregroundStyle(TildeColor.text)
                } else {
                    Text("Name")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let item { Text(item.address).tildeMono(12).foregroundStyle(TildeColor.text2) } else { Text("Address") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let item { EnvBadge(EnvTone(item.environment)) } else { Text("Environment") }
            }
            .frame(width: 96, alignment: .leading)
            Group {
                if let item {
                    if let date = item.lastConnectedAt {
                        Text(date, format: .relative(presentation: .named)).foregroundStyle(TildeColor.text2)
                    }
                } else {
                    Text("Last used")
                }
            }
            .frame(width: 130, alignment: .leading)
            Group {
                if let item { latencyCell(monitor.status(for: item.probeTarget)) } else { Text("Latency") }
            }
            .frame(width: 70, alignment: .leading)
        }
        .lineLimit(1)
        .font(header ? .system(size: 11, weight: .medium) : .system(size: 13))
        .foregroundStyle(header ? TildeColor.text3 : TildeColor.text)
        .padding(.horizontal, 12)
        .frame(height: header ? 26 : 30)
        .background(isSelected ? TildeColor.accentSoft : Color.clear)
        .overlay(alignment: .bottom) { if header { TildeColor.border.frame(height: TildeSpacing.hairline) } }
        .contentShape(Rectangle())
        .modifier(RecentRowActions(item: item, selection: $selection, open: { open([$0]) }, edit: { navigator.present(.editServer($0)) }))
    }

    @ViewBuilder
    private func latencyCell(_ status: ReachabilityMonitor.Status) -> some View {
        switch status {
        case .reachable(let ms):
            Text("\(ms) ms").tildeMono(12)
                .foregroundStyle(StatusDot.Kind(latencyMilliseconds: ms) == .slow ? TildeColor.warn : TildeColor.text2)
        case .unreachable:
            Text("down").tildeMono(12).foregroundStyle(TildeColor.danger)
        case .unknown, .probing:
            Text("–").foregroundStyle(TildeColor.text3)
        }
    }

    private func open(_ ids: Set<UUID>) {
        for id in ids {
            if let server = servers.first(where: { $0.id == id }) { launcher.open(server) }
        }
    }

    // MARK: Environments

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Environments")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(summaries) { summary in environmentCard(summary) }
            }
        }
    }

    private func environmentCard(_ summary: EnvironmentSummary) -> some View {
        let tone = EnvTone(summary.environment)
        let color = Self.color(for: summary.level)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tone == .none ? "No environment" : tone.accessibilityName)
                    .tildeText(14, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(TildeColor.text)
                Spacer(minLength: 4)
                EnvBadge(tone)
            }
            Text(summary.count == 1 ? "1 server" : "\(summary.count) servers")
                .tildeText(12, relativeTo: .caption)
                .foregroundStyle(TildeColor.text3)
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(summary.label).tildeText(12, weight: .medium, relativeTo: .caption).foregroundStyle(color)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TildeColor.surface, in: RoundedRectangle(cornerRadius: TildeRadius.card))
        .overlay(RoundedRectangle(cornerRadius: TildeRadius.card).stroke(summary.level == .ok || summary.level == .unknown ? TildeColor.border : color.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private static func color(for level: EnvironmentSummary.Level) -> Color {
        switch level {
        case .ok: TildeColor.ok
        case .slow: TildeColor.warn
        case .down: TildeColor.danger
        case .unknown: TildeColor.text3
        }
    }
}

#Preview("MacHomeView") {
    TildePreviewHost(openSession: false) { _ in MacHomeView() }
        .frame(width: 900, height: 640)
}
/// Selection, double-click and the context menu for a Recent row (none for the header).
private struct RecentRowActions: ViewModifier {
    let item: HomeServer?
    @Binding var selection: UUID?
    let open: (UUID) -> Void
    let edit: (UUID) -> Void

    func body(content: Content) -> some View {
        if let item {
            content
                .onTapGesture(count: 2) { open(item.id) }
                .onTapGesture { selection = item.id }
                .contextMenu {
                    Button("Connect") { open(item.id) }
                    Button("Edit…") { edit(item.id) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(item.id) }
        } else {
            content.accessibilityHidden(true)
        }
    }
}
#endif
