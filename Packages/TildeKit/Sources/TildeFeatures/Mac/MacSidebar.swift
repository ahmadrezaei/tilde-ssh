#if os(macOS)
import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// The Mac source list (design #A-main): one compact row per server, groups as collapsible sections, tags as
/// filters, and Quick Connect in the sidebar's own search field (⌘L).
///
/// - A server is listed once. Favorites carry a star and sort first inside their group.
/// - The search field is Quick Connect: text that parses as `user@host[:port]` adds a first "Connect to …" row, and
///   Return connects. `#tag` and `env:prod` filter, and tag rows in the Tags section add a `#tag` search token.
/// - Double-click or Return on a server connects; the context menu carries the other server actions.
/// - The footer is the iCloud sync status, not buttons. Keys, Snippets and Settings live in the menu bar.
public struct MacSidebar: View {
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.tildeSyncMonitor) private var syncMonitor
    @Environment(\.openSettings) private var openSettings

    @Query(sort: [SortDescriptor(\Server.sortIndex), SortDescriptor(\Server.name)]) private var servers: [Server]
    @Query(sort: [SortDescriptor(\ServerGroup.sortIndex), SortDescriptor(\ServerGroup.name)]) private var groups: [ServerGroup]
    @Query(sort: \Tag.name) private var tags: [Tag]

    @AppStorage(TildeSettings.serverSortKey) private var sortRaw = ServerSortMode.manual.rawValue
    @AppStorage(TildeSettings.showOfflineKey) private var showOffline = true
    @AppStorage(TildeSettings.onboardingDoneKey) private var onboardingDone = false

    @State private var searchText = ""
    @State private var tokens: [SidebarTagToken] = []
    @State private var selection: UUID?
    @FocusState private var isSearchFocused: Bool
    @State private var favoritesOnly = false
    @State private var isUngroupedExpanded = true
    @State private var isTagsExpanded = true
    @State private var pendingDelete: Server?
    @State private var showsNewGroup = false
    @State private var newGroupName = ""
    @State private var groupToRename: ServerGroup?
    @State private var renameText = ""
    @State private var pendingGroupDelete: ServerGroup?

    public init() {}

    public var body: some View {
        list
            .navigationTitle("Servers")
            .searchable(text: $searchText, tokens: $tokens, placement: .sidebar, prompt: "Search or user@host:port") { token in
                Text("#\(token.name)")
            }
            .searchFocused($isSearchFocused)
            .onSubmit(of: .search, submit)
            .onChange(of: navigator.focusSearchToken) {
                // The sidebar may have just been revealed; give the column a turn before asking for focus.
                Task { @MainActor in
                    await Task.yield()
                    isSearchFocused = true
                }
            }
            .onDeleteCommand { if let server = selectedServer { pendingDelete = server } }
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarSyncFooter(monitor: syncMonitor) }
            .toolbar { toolbarContent }
            .overlay { emptyOverlay }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete Server", role: .destructive) {
                    if let server = pendingDelete { actions.delete(server) }
                    pendingDelete = nil
                }
            } message: {
                Text("This removes it from all your devices and deletes its saved password. It cannot be undone.")
            }
            .confirmationDialog("Delete group \"\(pendingGroupDelete?.name ?? "")\"?", isPresented: Binding(get: { pendingGroupDelete != nil }, set: { if !$0 { pendingGroupDelete = nil } }), titleVisibility: .visible) {
                Button("Delete Group", role: .destructive) {
                    if let group = pendingGroupDelete { actions.delete(group) }
                    pendingGroupDelete = nil
                }
            } message: {
                Text("Servers in it move to the main list.")
            }
            .alert("New Group", isPresented: $showsNewGroup) {
                TextField("Name", text: $newGroupName)
                Button("Create") { actions.createGroup(named: newGroupName); newGroupName = "" }
                Button("Cancel", role: .cancel) { newGroupName = "" }
            }
            .alert("Rename Group", isPresented: Binding(get: { groupToRename != nil }, set: { if !$0 { groupToRename = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") { if let group = groupToRename { actions.rename(group, to: renameText) }; groupToRename = nil }
                Button("Cancel", role: .cancel) { groupToRename = nil }
            }
    }

    // MARK: Derived state

    private var actions: ServerActions { ServerActions(context: context, secrets: services.secretStore) }
    private var launcher: QuickConnectLauncher { QuickConnectLauncher(services: services, context: context, navigator: navigator) }
    private var monitor: ReachabilityMonitor { coordinator.reachability }
    private var sortMode: ServerSortMode { ServerSortMode(rawValue: sortRaw) ?? .manual }
    private var query: ServerQuery { ServerQuery(parsing: searchText, selectedTags: Set(tokens.map(\.id))) }
    private var isFiltering: Bool { !query.isEmpty }
    private var selectedServer: Server? { selection.flatMap { id in servers.first { $0.id == id } } }

    private var visibleServers: [Server] {
        let shown = showOffline ? servers : servers.filter { server in
            if case .unreachable = monitor.status(for: probeTarget(server)) { return false }
            return true
        }
        return favoritesOnly ? shown.filter(\.isFavorite) : shown
    }

    /// Free-text search ranks its matches in one flat list; tag and environment filters keep the group layout.
    private var rankedResults: [Server]? {
        let q = query
        return q.words.isEmpty ? nil : ServerListing.ranked(visibleServers, query: q)
    }

    private var layout: ServerSections<Server> {
        ServerListing.sections(
            ServerListing.filtered(visibleServers, query: query),
            groupIDs: groups.map(\.id), mode: sortMode, favoritesFirst: true
        )
    }

    /// The `Connect to …` row: the text parses as a target and looks like one.
    private var connectCandidate: QuickConnectResult? {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let result = launcher.parse(text) else { return nil }
        let noMatches = ServerListing.ranked(visibleServers, query: query).isEmpty
        return ServerListing.looksLikeTarget(text) || noMatches ? result : nil
    }

    private var taggedNames: [Tag] { tags.filter { !($0.servers ?? []).isEmpty } }

    private func probeTarget(_ server: Server) -> ConnectionTarget {
        // Servers behind a jump host probe the bastion instead (design section 4.1).
        ServerMapper.target(server.jumpServer ?? server)
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            if let candidate = connectCandidate { connectSection(candidate) }
            if let results = rankedResults {
                Section {
                    ForEach(results) { row($0) }
                } header: {
                    sectionHeader("Results", count: results.count)
                }
            } else {
                let layout = layout
                ForEach(groups) { group in
                    let members = layout.groups[group.id] ?? []
                    if !(isFiltering && members.isEmpty) { groupSection(group, members: members) }
                }
                if !layout.ungrouped.isEmpty {
                    Section(isExpanded: Binding(get: { isUngroupedExpanded || isFiltering }, set: { if !isFiltering { isUngroupedExpanded = $0 } })) {
                        ForEach(layout.ungrouped) { row($0) }
                            .onMove { from, to in actions.reorder(layout.ungrouped, fromOffsets: from, toOffset: to) }
                            .moveDisabled(!canReorder(layout.ungrouped))
                    } header: {
                        sectionHeader(groups.isEmpty ? "Servers" : "Ungrouped", count: layout.ungrouped.count)
                    }
                }
            }
            if !taggedNames.isEmpty { tagsSection }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let server = server(for: ids) { contextMenu(for: server) }
        } primaryAction: { ids in
            if let server = server(for: ids) { launcher.open(server) }
        }
    }

    private func server(for ids: Set<UUID>) -> Server? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return servers.first { $0.id == id }
    }

    /// Dragging to reorder is only meaningful in manual order with nothing hidden or floated: favorites sort first, so
    /// the displayed order of a list that has any would not match the stored one.
    private func canReorder(_ list: [Server]) -> Bool {
        sortMode == .manual && showOffline && !favoritesOnly && !isFiltering && !list.contains(where: \.isFavorite)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 0)
            Text("\(count)").font(TildeFont.sidebarCaption).foregroundStyle(TildeColor.text3)
        }
        .accessibilityElement(children: .combine)
    }

    private func connectSection(_ candidate: QuickConnectResult) -> some View {
        Section {
            Button { launcher.connect(candidate) } label: { ConnectToRow(target: candidate.target) }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { launcher.connect(candidate) } label: { Label("Connect", systemImage: "bolt") }
                    Button { saveAsServer(candidate) } label: { Label("Save as Server…", systemImage: "square.and.arrow.down") }
                }
        }
    }

    private func groupSection(_ group: ServerGroup, members: [Server]) -> some View {
        Section(isExpanded: Binding(
            get: { !group.isCollapsed || isFiltering },
            // While filtering every section is forced open, so a collapse made then must not be saved (it syncs).
            set: { if !isFiltering { actions.setCollapsed(group, !$0) } }
        )) {
            ForEach(members) { row($0) }
                .onMove { from, to in actions.reorder(members, fromOffsets: from, toOffset: to) }
                .moveDisabled(!canReorder(members))
        } header: {
            sectionHeader(group.name, count: members.count)
                .contextMenu {
                    Button { renameText = group.name; groupToRename = group } label: { Label("Rename…", systemImage: "pencil") }
                    Button(role: .destructive) { pendingGroupDelete = group } label: { Label("Delete Group…", systemImage: "trash") }
                }
        }
    }

    private var tagsSection: some View {
        Section(isExpanded: $isTagsExpanded) {
            ForEach(taggedNames) { tag in
                let token = SidebarTagToken(name: tag.name)
                let isOn = tokens.contains(token)
                Button { toggle(token) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isOn ? "checkmark" : "number")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isOn ? TildeColor.accent : TildeColor.text3)
                            .frame(width: TildeSpacing.statusDot + 2)
                            .accessibilityHidden(true)
                        Text(tag.name).font(TildeFont.sidebarRow).foregroundStyle(isOn ? TildeColor.accent : TildeColor.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\((tag.servers ?? []).count)").font(TildeFont.sidebarCaption).foregroundStyle(TildeColor.text3)
                    }
                    .frame(minHeight: TildeSpacing.sidebarRowHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
                .accessibilityHint("Filters the list by this tag")
            }
        } header: {
            Text("Tags")
        }
    }

    private func toggle(_ token: SidebarTagToken) {
        if let index = tokens.firstIndex(of: token) { tokens.remove(at: index) } else { tokens.append(token) }
    }

    // MARK: Rows

    private func row(_ server: Server) -> some View {
        MacServerRow(server: server, isLive: coordinator.isLive(serverID: server.id), status: monitor.status(for: probeTarget(server)))
            .tag(server.id)
            .onAppear { monitor.refresh(probeTarget(server)) }
    }

    @ViewBuilder
    private func contextMenu(for server: Server) -> some View {
        Button { launcher.open(server) } label: { Label("Connect", systemImage: "bolt") }
        Button { launcher.open(server, newSession: true) } label: { Label("New Session", systemImage: "plus.rectangle.on.rectangle") }
        Button { navigator.present(.editServer(server.id)) } label: { Label("Edit…", systemImage: "pencil") }
        Button { actions.duplicate(server) } label: { Label("Duplicate", systemImage: "doc.on.doc") }
        Divider()
        Button { Platform.copy(SSHCommand.string(for: ServerMapper.snapshot(server))) } label: { Label("Copy SSH Command", systemImage: "terminal") }
        Button { Platform.copy(server.host) } label: { Label("Copy Host", systemImage: "network") }
        Button { actions.toggleFavorite(server) } label: {
            Label(server.isFavorite ? "Remove from Favorites" : "Favorite", systemImage: server.isFavorite ? "star.slash" : "star")
        }
        Menu {
            Button { actions.move(server, to: nil) } label: { Label("Ungrouped", systemImage: server.group == nil ? "checkmark" : "tray") }
            ForEach(groups) { group in
                Button { actions.move(server, to: group) } label: { Label(group.name, systemImage: server.group?.id == group.id ? "checkmark" : group.symbol) }
            }
            Divider()
            Button { showsNewGroup = true } label: { Label("New Group…", systemImage: "folder.badge.plus") }
        } label: { Label("Move to Group", systemImage: "folder") }
        Divider()
        Button(role: .destructive) { pendingDelete = server } label: { Label("Delete…", systemImage: "trash") }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { navigator.present(.newServer) } label: { Label("New Server", systemImage: "server.rack") }
                Button { showsNewGroup = true } label: { Label("New Group…", systemImage: "folder.badge.plus") }
                Button { navigator.present(.importSSHConfig) } label: { Label("Import ~/.ssh/config…", systemImage: "square.and.arrow.down") }
                Button { navigator.present(.generateKey) } label: { Label("Generate Key…", systemImage: "key") }
                Divider()
                Picker("Sort", selection: $sortRaw) {
                    ForEach(ServerSortMode.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0.rawValue) }
                }
                Toggle(isOn: $showOffline) { Label("Show Offline Servers", systemImage: "eye") }
                Toggle(isOn: $favoritesOnly) { Label("Favorites Only", systemImage: "star") }
            } label: {
                Image(systemName: "plus")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Add and organize")
            .help("Add a server, import, sort and group")
        }
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyOverlay: some View {
        if servers.isEmpty && !isFiltering {
            if onboardingDone {
                EmptyState("No servers yet.", message: "Add one, or type user@host in the search field and press return.") {
                    VStack(spacing: TildeSpacing.s) {
                        Button("Add server") { navigator.present(.newServer) }.buttonStyle(.tildePrimary)
                        Button("Quick connect") { navigator.focusSearch() }.buttonStyle(.tildeSecondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TildeColor.bg)
            } else {
                OnboardingView(
                    iCloudAvailable: syncMonitor.map { SidebarSyncSummary.isAvailable($0.status) } ?? false,
                    onAddServer: { navigator.present(.newServer) },
                    onImport: { navigator.present(.importSSHConfig) },
                    onGenerateKey: { navigator.present(.generateKey) },
                    onSkip: { onboardingDone = true },
                    onOpenSettings: { openSettings() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TildeColor.bg)
            }
        }
    }

    // MARK: Actions

    private var deleteTitle: String { "Delete \(pendingDelete.map(ServerMapper.displayName) ?? "server")?" }

    private func submit() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let candidate = connectCandidate
        // Return opens the first row of the Results list. Without free text the list is grouped, not ranked, so
        // there is no "first result" to open; only a Connect row can be taken.
        let found = rankedResults ?? []
        switch ServerListing.submission(hasCandidate: candidate != nil, rawText: searchText, hasResults: !found.isEmpty) {
        case .connect:
            if let candidate { launcher.connect(candidate) }
        case .openFirstResult:
            if let first = found.first { launcher.open(first) }
        case .nothing:
            break
        }
        searchText = ""
    }

    private func saveAsServer(_ candidate: QuickConnectResult) {
        let snapshot = ServerSnapshot(name: candidate.target.host, target: candidate.target, auth: .passwordPrompt)
        navigator.present(.saveServer(SaveServerRequest(server: snapshot, password: nil)))
    }
}

/// A tag filter shown as a pill in the search field. Matching is case-insensitive, like `ServerQuery`.
struct SidebarTagToken: Identifiable, Hashable {
    let name: String
    var id: String { name.lowercased() }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The sidebar footer's one line: where servers are stored and, with iCloud, how sync is going.
struct SidebarSyncSummary: Equatable {
    var text: String
    var symbol: String
    /// Sync wants attention (signed out, restricted, failing).
    var needsAttention: Bool

    /// - Parameters:
    ///   - status: `nil` when the app has no sync monitor (previews, tests): servers are local.
    ///   - lastSync: the end of the last successful import or export.
    ///   - now: injected so tests do not depend on the clock.
    init(status: SyncStatus?, lastSync: Date?, now: Date) {
        switch status {
        case nil, .disabled:
            self = SidebarSyncSummary(text: "On this Mac", symbol: "desktopcomputer", needsAttention: false)
        case .noAccount:
            self = SidebarSyncSummary(text: "iCloud · signed out", symbol: "exclamationmark.icloud", needsAttention: true)
        case .restricted:
            self = SidebarSyncSummary(text: "iCloud · restricted", symbol: "exclamationmark.icloud", needsAttention: true)
        case .temporarilyUnavailable:
            self = SidebarSyncSummary(text: "iCloud · unavailable", symbol: "exclamationmark.icloud", needsAttention: true)
        case .syncing:
            self = SidebarSyncSummary(text: "iCloud · syncing…", symbol: "arrow.triangle.2.circlepath.icloud", needsAttention: false)
        case .error:
            self = SidebarSyncSummary(text: "iCloud · sync failed", symbol: "exclamationmark.icloud", needsAttention: true)
        case .upToDate:
            let text = lastSync.map { "iCloud · synced \(Self.relative($0, to: now))" } ?? "iCloud · up to date"
            self = SidebarSyncSummary(text: text, symbol: "checkmark.icloud", needsAttention: false)
        }
    }

    private init(text: String, symbol: String, needsAttention: Bool) {
        self.text = text
        self.symbol = symbol
        self.needsAttention = needsAttention
    }

    /// Whether the store is syncing, or will once the account allows it (what onboarding calls "iCloud available").
    static func isAvailable(_ status: SyncStatus) -> Bool {
        switch status {
        case .disabled, .noAccount, .restricted: false
        case .temporarilyUnavailable, .upToDate, .syncing, .error: true
        }
    }

    static func relative(_ date: Date, to now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// `iCloud · synced 2 min. ago`, status only: no buttons.
private struct SidebarSyncFooter: View {
    let monitor: SyncStatusMonitor?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let summary = SidebarSyncSummary(status: monitor?.status, lastSync: monitor?.lastSyncDate, now: timeline.date)
            HStack(spacing: 6) {
                Image(systemName: summary.symbol)
                    .foregroundStyle(summary.needsAttention ? TildeColor.warn : TildeColor.text3)
                    .accessibilityHidden(true)
                Text(summary.text).foregroundStyle(TildeColor.text3).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(TildeFont.sidebarChrome)
            .padding(.horizontal, TildeSpacing.m)
            .padding(.vertical, TildeSpacing.s)
            .accessibilityElement(children: .combine)
        }
    }
}

#Preview("MacSidebar") {
    TildePreviewHost(openSession: true) { _ in
        NavigationSplitView { MacSidebar() } detail: { Text("Detail") }
    }
}
#endif
