import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// The server list (design section 4.1): pinned search / Quick Connect field, tag chips, LIVE, FAVORITES, one
/// collapsible section per group, then the rest. Used as the iPhone Servers tab and as the iPad sidebar (the Mac sidebar is `MacSidebar`).
public struct ServerList: View {
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.tildeSyncMonitor) private var syncMonitor
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    @Query(sort: [SortDescriptor(\Server.sortIndex), SortDescriptor(\Server.name)]) private var servers: [Server]
    @Query(sort: [SortDescriptor(\ServerGroup.sortIndex), SortDescriptor(\ServerGroup.name)]) private var groups: [ServerGroup]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @Query(sort: \RecentConnection.lastUsedAt, order: .reverse) private var recents: [RecentConnection]

    @AppStorage(TildeSettings.serverSortKey) private var sortRaw = ServerSortMode.manual.rawValue
    @AppStorage(TildeSettings.showOfflineKey) private var showOffline = true
    @AppStorage(TildeSettings.onboardingDoneKey) private var onboardingDone = false

    @State private var searchText = ""
    @State private var selectedTags: Set<String> = []
    @FocusState private var isSearchFocused: Bool
    @State private var pendingDelete: Server?
    @State private var showsNewGroup = false
    @State private var newGroupName = ""
    @State private var groupToRename: ServerGroup?
    @State private var renameText = ""
    @State private var pendingGroupDelete: ServerGroup?

    public init() {}

    public var body: some View {
        styledList
            .navigationTitle("Servers")
            .searchable(text: $searchText, placement: searchPlacement, prompt: "Search or user@host:port")
            .searchFocused($isSearchFocused)
            .searchSuggestions { recentSuggestions }
            .onSubmit(of: .search, submit)
            .refreshable { probeAll(force: true) }
            .toolbar { toolbarContent }
            .overlay { emptyOverlay }
            .onChange(of: navigator.focusSearchToken) { isSearchFocused = true }
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
    private var query: ServerQuery { ServerQuery(parsing: searchText, selectedTags: selectedTags) }
    private var isFiltering: Bool { !query.isEmpty }
    private var useSidebarStyle: Bool { Platform.isMac || sizeClass == .regular }

    private var visibleServers: [Server] {
        showOffline ? servers : servers.filter { server in
            if case .unreachable = monitor.status(for: probeTarget(server)) { return false }
            return true
        }
    }

    private var results: [Server] { ServerListing.ranked(visibleServers, query: query) }

    /// The `↵ Connect to ...` candidate: the text parses as a target and looks like one (not just a word that
    /// happens to match a server name).
    private var connectCandidate: QuickConnectResult? {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let result = launcher.parse(text) else { return nil }
        return ServerListing.looksLikeTarget(text) || results.isEmpty ? result : nil
    }

    private var liveTabs: [SessionTab] { navigator.tabs.filter(\.isLive) }
    private var favorites: [Server] { sorted(visibleServers.filter(\.isFavorite)) }
    private var ungrouped: [Server] { sorted(visibleServers.filter { $0.group == nil }) }
    private func servers(in group: ServerGroup) -> [Server] { sorted(visibleServers.filter { $0.group?.id == group.id }) }

    private func sorted(_ list: [Server]) -> [Server] { ServerListing.sorted(list, mode: sortMode) }

    private func probeTarget(_ server: Server) -> ConnectionTarget {
        // Servers behind a jump host probe the bastion instead (design section 4.1).
        ServerMapper.target(server.jumpServer ?? server)
    }

    private var searchPlacement: SearchFieldPlacement {
        #if os(macOS)
        .sidebar
        #else
        sizeClass == .regular ? .sidebar : .navigationBarDrawer(displayMode: .always)
        #endif
    }

    // MARK: List

    @ViewBuilder
    private var styledList: some View {
        #if os(macOS)
        listBody.listStyle(.sidebar)
        #else
        if sizeClass == .regular { listBody.listStyle(.sidebar) } else { listBody.listStyle(.insetGrouped) }
        #endif
    }

    private var listBody: some View {
        List {
            if !tags.isEmpty { tagChips }
            if let candidate = connectCandidate { connectSection(candidate) }

            if isFiltering {
                Section {
                    ForEach(results) { row($0) }
                } header: {
                    SectionHeader("Results", count: results.count)
                }
            } else {
                if !liveTabs.isEmpty { liveSection }
                if !favorites.isEmpty {
                    Section { ForEach(favorites) { row($0) } } header: { SectionHeader("Favorites", systemImage: "star.fill", count: favorites.count) }
                }
                ForEach(groups) { group in groupSection(group) }
                if !ungrouped.isEmpty {
                    Section {
                        ForEach(ungrouped) { row($0) }
                            .onMove { from, to in move(ungrouped, from, to) }
                            .moveDisabled(sortMode != .manual || !showOffline)
                    } header: {
                        SectionHeader(groups.isEmpty ? "Servers" : "Ungrouped", count: ungrouped.count)
                    }
                }
            }
        }
        .tildeList()
    }

    private var tagChips: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    TagChip("All", isOn: selectedTags.isEmpty) { selectedTags.removeAll() }
                    ForEach(tags.filter { !($0.servers ?? []).isEmpty }) { tag in
                        TagChip(tag.name, isOn: selectedTags.contains(tag.name.lowercased())) {
                            let key = tag.name.lowercased()
                            if selectedTags.contains(key) { selectedTags.remove(key) } else { selectedTags.insert(key) }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func connectSection(_ candidate: QuickConnectResult) -> some View {
        Section {
            Button { launcher.connect(candidate) } label: { ConnectToRow(target: candidate.target) }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button("Save…") { saveAsServer(candidate) }.tint(TildeColor.info)
                }
                .contextMenu {
                    Button { launcher.connect(candidate) } label: { Label("Connect", systemImage: "bolt") }
                    Button { saveAsServer(candidate) } label: { Label("Save as Server…", systemImage: "square.and.arrow.down") }
                }
                .listRowBackground(TildeColor.accentSoft)
        }
    }

    private var liveSection: some View {
        Section {
            ForEach(liveTabs) { tab in
                Button { coordinator.select(tab); navigator.showDeckIfCompact() } label: { LiveSessionRow(tab: tab) }
                    .buttonStyle(.plain)
                    .tildeRowBackground()
                    .swipeActions(edge: .trailing) {
                        Button("Close", role: .destructive) { coordinator.close(tab) }
                    }
            }
        } header: {
            SectionHeader("Live", count: liveTabs.count)
        }
    }

    private func groupSection(_ group: ServerGroup) -> some View {
        let members = servers(in: group)
        return Section {
            if !group.isCollapsed {
                ForEach(members) { row($0) }
                    .onMove { from, to in move(members, from, to) }
                    .moveDisabled(sortMode != .manual || !showOffline)
            }
        } header: {
            Button { withAnimation(.snappy) { actions.setCollapsed(group, !group.isCollapsed) } } label: {
                SectionHeader(group.name, systemImage: group.symbol, count: members.count, isExpanded: !group.isCollapsed)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { renameText = group.name; groupToRename = group } label: { Label("Rename…", systemImage: "pencil") }
                Button(role: .destructive) { pendingGroupDelete = group } label: { Label("Delete Group…", systemImage: "trash") }
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ server: Server) -> some View {
        Button { launcher.open(server) } label: {
            ServerRow(server: server, isLive: coordinator.isLive(serverID: server.id), status: monitor.status(for: probeTarget(server)))
        }
        .buttonStyle(.plain)
        .tildeRowBackground()
        .onAppear { monitor.refresh(probeTarget(server)) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { launcher.open(server, newSession: true) } label: { Label("New session", systemImage: "plus.rectangle.on.rectangle") }
                .tint(TildeColor.accentStrong)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { pendingDelete = server } label: { Label("Delete", systemImage: "trash") }
            Button { navigator.present(.editServer(server.id)) } label: { Label("Edit", systemImage: "pencil") }
                .tint(TildeColor.info)
        }
        .contextMenu { contextMenu(for: server) }
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

    // MARK: Search suggestions

    @ViewBuilder
    private var recentSuggestions: some View {
        if searchText.isEmpty {
            ForEach(recents.prefix(10)) { recent in
                Label(recent.target, systemImage: "clock.arrow.circlepath")
                    .tildeMono(13, relativeTo: .subheadline)
                    .searchCompletion(recent.target)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { navigator.present(.newServer) } label: { Label("New Server", systemImage: "server.rack") }
                Button { navigator.present(.importSSHConfig) } label: {
                    Label(Platform.isMac ? "Import ~/.ssh/config…" : "Import from File…", systemImage: "square.and.arrow.down")
                }
                Button { navigator.present(.generateKey) } label: { Label("Generate Key…", systemImage: "key") }
            } label: {
                Image(systemName: "plus")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Add")
            .help("Add a server, import, or generate a key")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(ServerSortMode.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0.rawValue) }
                }
                Toggle(isOn: $showOffline) { Label("Show Offline Servers", systemImage: "eye") }
                Divider()
                Button { showsNewGroup = true } label: { Label("New Group…", systemImage: "folder.badge.plus") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
            .help("Sort, filter and group servers")
        }
    }

    // MARK: Empty state

    @ViewBuilder
    private var emptyOverlay: some View {
        if servers.isEmpty && !isFiltering {
            if onboardingDone {
                // A scroll view (like the onboarding view) gives the large "Servers" title content to track; a
                // plain centred view makes the title disappear on iPhone.
                ScrollView {
                    EmptyState("No servers yet.", message: "Add one, or type user@host in the search field and press return.") {
                        VStack(spacing: TildeSpacing.s) {
                            Button("Add server") { navigator.present(.newServer) }.buttonStyle(.tildePrimary)
                            Button("Quick connect") { navigator.focusSearch() }.buttonStyle(.tildeSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .containerRelativeFrame(.vertical, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
                .background(TildeColor.bg)
            } else {
                OnboardingView(
                    iCloudAvailable: iCloudAvailable,
                    onAddServer: { navigator.present(.newServer) },
                    onImport: { navigator.present(.importSSHConfig) },
                    onGenerateKey: { navigator.present(.generateKey) },
                    onSkip: { onboardingDone = true },
                    onOpenSettings: openSettingsScreen
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TildeColor.bg)
            }
        }
    }

    /// Whether servers are being synced: the store is a CloudKit store and the iCloud account can use it.
    private var iCloudAvailable: Bool {
        guard let syncMonitor else { return false }
        switch syncMonitor.status {
        case .disabled, .noAccount, .restricted: return false
        case .temporarilyUnavailable, .upToDate, .syncing, .error: return true
        }
    }

    private func openSettingsScreen() {
        #if os(macOS)
        openSettings()
        #else
        navigator.present(.settings)
        #endif
    }

    // MARK: Actions

    private var deleteTitle: String { "Delete \(pendingDelete.map(ServerMapper.displayName) ?? "server")?" }

    private func submit() {
        let candidate = connectCandidate
        let found = results
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

    private func move(_ list: [Server], _ from: IndexSet, _ to: Int) {
        actions.reorder(list, fromOffsets: from, toOffset: to)
    }

    private func probeAll(force: Bool) {
        for server in servers { monitor.refresh(probeTarget(server), force: force) }
    }
}

#Preview("ServerList") {
    TildePreviewHost(openSession: true) { _ in
        NavigationStack { ServerList() }
    }
}

#Preview("ServerList: empty") {
    TildePreviewHost(openSession: false) { _ in
        // swiftlint:disable:next force_try
        NavigationStack { ServerList().modelContainer(try! ModelContainerFactory.make(.inMemory)) }
    }
}
