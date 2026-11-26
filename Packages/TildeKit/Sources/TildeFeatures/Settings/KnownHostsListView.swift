import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// Settings > Security > Known Hosts: every pinned host key, grouped by host, with search, a detail page and
/// "Forget". Place it inside a `NavigationStack` (`SecuritySettingsSection(knownHosts:)` pushes it).
///
/// Forgetting a pin means the next connection to that host asks the user to trust its key again, so every
/// removal goes through a confirmation. Pins that two devices disagreed on are marked in the danger colour.
public struct KnownHostsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\KnownHost.endpoint), SortDescriptor(\KnownHost.algorithm)]) private var allHosts: [KnownHost]

    @State private var searchText = ""
    @State private var pendingForget: KnownHost?
    @State private var errorMessage: String?

    public init() {}

    public var body: some View {
        Group {
            if pins.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(TildeColor.bg)
        .navigationTitle("Known Hosts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .searchable(text: $searchText, prompt: "Search hosts or fingerprints")
        .confirmationDialog(
            "Forget the host key for \(pendingForget?.endpoint ?? "this host")?",
            isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget Host Key", role: .destructive) {
                if let host = pendingForget { forget(host) }
                pendingForget = nil
            }
        } message: {
            Text("The key is removed from all your devices. The next connection to this host asks you to trust its key again.")
        }
        .alert("Could not forget the host key", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Data

    /// Every pin except forgotten ones.
    private var pins: [KnownHost] { allHosts.filter { $0.status != .revoked } }

    private var filtered: [KnownHost] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return pins }
        return pins.filter {
            $0.endpoint.localizedCaseInsensitiveContains(query)
                || $0.fingerprintSHA256.localizedCaseInsensitiveContains(query)
                || $0.algorithm.localizedCaseInsensitiveContains(query)
        }
    }

    /// One group per endpoint, sorted by host name then port (the query already orders by endpoint).
    private var groups: [(endpoint: String, hosts: [KnownHost])] {
        Dictionary(grouping: filtered, by: \.endpoint)
            .map { (endpoint: $0.key, hosts: $0.value.sorted { $0.algorithm < $1.algorithm }) }
            .sorted { sortKey($0.endpoint).localizedStandardCompare(sortKey($1.endpoint)) == .orderedAscending }
    }

    /// `[host]:port` sorts by `host`, like a plain `host`.
    private func sortKey(_ endpoint: String) -> String { endpoint.hasPrefix("[") ? String(endpoint.dropFirst()) : endpoint }

    private var conflictCount: Int { pins.filter { $0.status == .conflicted }.count }

    // MARK: Pieces

    private var list: some View {
        List {
            if conflictCount > 0 {
                Section {
                    Banner(
                        .error,
                        headline: conflictCount == 1 ? "1 host key is in conflict" : "\(conflictCount) host keys are in conflict",
                        detail: "Two of your devices trusted different keys for the same host. Connect to the host and compare the fingerprint before you trust either."
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            if groups.isEmpty {
                Section {
                    Text("No hosts match “\(searchText)”.")
                        .foregroundStyle(TildeColor.text2)
                        .listRowBackground(TildeColor.surface2)
                }
            }
            ForEach(groups, id: \.endpoint) { group in
                Section {
                    ForEach(group.hosts) { host in
                        NavigationLink {
                            KnownHostDetailView(host: host, forget: forget)
                        } label: {
                            KnownHostRow(host: host)
                        }
                        .listRowBackground(TildeColor.surface2)
                        .listRowSeparatorTint(TildeColor.border)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Forget", role: .destructive) { pendingForget = host }
                        }
                        .contextMenu {
                            Button("Copy Fingerprint", systemImage: "doc.on.doc") { Platform.copy(host.fingerprintSHA256) }
                            Button("Forget Host Key…", systemImage: "trash", role: .destructive) { pendingForget = host }
                        }
                    }
                } header: {
                    Text(group.endpoint)
                        .tildeMono(12, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(TildeColor.text2)
                        .textCase(nil)
                }
            }
        }
        .tildeFormStyle()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No known hosts.", systemImage: "checkmark.shield")
        } description: {
            Text("Host keys appear here after you trust a server on first connect. Pins sync across your devices.")
        }
    }

    // MARK: Actions

    private func forget(_ host: KnownHost) {
        do {
            try KnownHostRepository(context: context).forget(host)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Formatting shared by the list and the detail page.
enum KnownHostFormat {
    /// `ssh-ed25519` becomes `ED25519`, `ecdsa-sha2-nistp256` becomes `ECDSA-P256`, `ssh-rsa` becomes `RSA`.
    static func algorithmBadge(_ algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512": "RSA"
        case "ecdsa-sha2-nistp256": "ECDSA-P256"
        case "ecdsa-sha2-nistp384": "ECDSA-P384"
        case "ecdsa-sha2-nistp521": "ECDSA-P521"
        default: algorithm.uppercased()
        }
    }

    static func date(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

    static func statusTitle(_ status: KnownHostStatus) -> String {
        switch status {
        case .trusted: "Trusted"
        case .conflicted: "Conflicted"
        case .revoked: "Forgotten"
        }
    }
}

/// One row of the Mac Known Hosts table: a pinned key split into the columns the table shows. A value type, so the
/// table can sort and filter without touching the model objects, and so the logic is unit tested.
struct KnownHostTableRow: Identifiable, Hashable {
    let id: UUID
    /// The canonical endpoint (`host` or `[host]:port`), as stored and as searched.
    let endpoint: String
    let host: String
    let port: Int
    /// The raw algorithm name (`ssh-ed25519`).
    let algorithm: String
    /// The short badge (`ED25519`).
    let keyType: String
    let fingerprint: String
    let added: Date
    let isConflicted: Bool

    init(_ pin: KnownHost) {
        let parsed = Self.parse(endpoint: pin.endpoint)
        id = pin.id
        endpoint = pin.endpoint
        host = parsed.host
        port = parsed.port
        algorithm = pin.algorithm
        keyType = KnownHostFormat.algorithmBadge(pin.algorithm)
        fingerprint = pin.fingerprintSHA256
        added = pin.firstSeenAt
        isConflicted = pin.status == .conflicted
    }

    /// Splits a canonical endpoint. Only `[host]:port` carries a port; anything else is the host on port 22, which
    /// includes a bare IPv6 address such as `::1`. A malformed bracket form is shown as it is, on port 22.
    static func parse(endpoint: String) -> (host: String, port: Int) {
        guard endpoint.hasPrefix("["), let close = endpoint.firstIndex(of: "]") else { return (endpoint, 22) }
        let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
        let rest = endpoint[endpoint.index(after: close)...]
        guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return (endpoint, 22) }
        return (host, port)
    }

    /// Whether the row matches a search: the endpoint, the fingerprint or the algorithm contains `query`.
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return endpoint.localizedCaseInsensitiveContains(query)
            || fingerprint.localizedCaseInsensitiveContains(query)
            || algorithm.localizedCaseInsensitiveContains(query)
    }

    /// The selected ids that are still on screen. A search can hide selected rows, and Remove must never forget a
    /// key the user cannot see.
    static func visibleSelection(_ selection: Set<UUID>, in rows: [KnownHostTableRow]) -> Set<UUID> {
        selection.intersection(rows.map(\.id))
    }

    /// The rows to show: forgotten pins left out, filtered by `query`, ordered by host name, then port, then algorithm.
    static func rows(from pins: [KnownHost], matching query: String = "") -> [KnownHostTableRow] {
        pins
            .filter { $0.status != .revoked }
            .map(KnownHostTableRow.init)
            .filter { $0.matches(query) }
            .sorted { lhs, rhs in
                let byHost = lhs.host.localizedStandardCompare(rhs.host)
                if byHost != .orderedSame { return byHost == .orderedAscending }
                if lhs.port != rhs.port { return lhs.port < rhs.port }
                return lhs.algorithm < rhs.algorithm
            }
    }
}

/// Forgetting several pins at once (the Mac table's multi-select). Each pin is its own save, so one failure must not
/// stop the rest.
@MainActor
enum KnownHostRemoval {
    /// Forgets every pin whose id is in `ids`. Returns the first error's message, or `nil` when all were forgotten.
    static func forget(ids: Set<UUID>, from pins: [KnownHost], repository: KnownHostRepository) -> String? {
        var firstError: String?
        for pin in pins where ids.contains(pin.id) {
            do {
                try repository.forget(pin)
            } catch {
                firstError = firstError ?? error.localizedDescription
            }
        }
        return firstError
    }
}

#if os(macOS)
/// The Mac Settings > Known Hosts pane: every pinned host key in a native `Table` (host, port, key type, SHA256
/// fingerprint, added), with search, sortable columns, multi-select and Remove. A removal asks first: the key is
/// forgotten on every device, and the next connection asks to trust it again. Conflicted pins are drawn in red.
struct KnownHostsTable: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\KnownHost.endpoint), SortDescriptor(\KnownHost.algorithm)]) private var allPins: [KnownHost]

    @State private var searchText = ""
    @State private var selection: Set<UUID> = []
    @State private var sortOrder: [KeyPathComparator<KnownHostTableRow>] = []
    @State private var pendingForget: Set<UUID> = []
    @State private var errorMessage: String?

    private var pins: [KnownHost] { allPins.filter { $0.status != .revoked } }
    private var rows: [KnownHostTableRow] { KnownHostTableRow.rows(from: allPins, matching: searchText).sorted(using: sortOrder) }
    private var conflictCount: Int { pins.filter { $0.status == .conflicted }.count }
    private var visibleSelection: Set<UUID> { KnownHostTableRow.visibleSelection(selection, in: rows) }

    var body: some View {
        VStack(spacing: 0) {
            if pins.isEmpty {
                emptyState
            } else {
                searchField
                Divider().overlay(TildeColor.border)
                if conflictCount > 0 { conflictBanner }
                table
            }
            Divider().overlay(TildeColor.border)
            footer
        }
        .background(TildeColor.bg)
        .confirmationDialog(
            pendingTitle,
            isPresented: Binding(get: { !pendingForget.isEmpty }, set: { if !$0 { pendingForget = [] } }),
            titleVisibility: .visible
        ) {
            Button(pendingForget.count == 1 ? "Forget Host Key" : "Forget Host Keys", role: .destructive) {
                errorMessage = KnownHostRemoval.forget(ids: pendingForget, from: allPins, repository: KnownHostRepository(context: context))
                selection.subtract(pendingForget)
                pendingForget = []
            }
        } message: {
            Text("The key is removed from all your devices. The next connection to this host asks you to trust its key again.")
        }
        .alert("Could not forget the host key", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var pendingTitle: String {
        if pendingForget.count == 1, let pin = allPins.first(where: { pendingForget.contains($0.id) }) {
            return "Forget the host key for \(pin.endpoint)?"
        }
        return "Forget \(pendingForget.count) host keys?"
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: TildeSpacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(TildeColor.text3).accessibilityHidden(true)
            TextField("", text: $searchText, prompt: Text("Search hosts or fingerprints").foregroundStyle(TildeColor.text3))
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .accessibilityLabel("Search hosts or fingerprints")
        }
        .padding(.horizontal, TildeSpacing.l)
        .frame(minHeight: 38)
        .background(TildeColor.surface)
    }

    private var conflictBanner: some View {
        Banner(
            .error,
            headline: conflictCount == 1 ? "1 host key is in conflict" : "\(conflictCount) host keys are in conflict",
            detail: "Two of your devices trusted different keys for the same host. Connect to the host and compare the fingerprint before you trust either."
        )
        .padding(TildeSpacing.m)
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Host", value: \.host) { row in
                HStack(spacing: TildeSpacing.xs) {
                    if row.isConflicted {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TildeColor.danger).accessibilityLabel("Conflicted")
                    }
                    Text(row.host).foregroundStyle(row.isConflicted ? TildeColor.danger : TildeColor.text)
                }
            }
            .width(min: 120, ideal: 170)
            TableColumn("Port", value: \.port) { row in
                Text(verbatim: "\(row.port)").foregroundStyle(row.isConflicted ? TildeColor.danger : TildeColor.text2)
            }
            .width(min: 44, ideal: 56, max: 72)
            TableColumn("Key Type", value: \.keyType) { row in
                Text(row.keyType).foregroundStyle(row.isConflicted ? TildeColor.danger : TildeColor.text2)
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("Fingerprint", value: \.fingerprint) { row in
                Text(row.fingerprint)
                    .font(TildeFont.mono(12))
                    .foregroundStyle(row.isConflicted ? TildeColor.danger : TildeColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .width(min: 180, ideal: 280)
            TableColumn("Added", value: \.added) { row in
                Text(KnownHostFormat.date(row.added)).foregroundStyle(TildeColor.text2)
            }
            .width(min: 90, ideal: 110, max: 140)
        }
        .tableStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if rows.isEmpty { ContentUnavailableView.search(text: searchText) }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                if ids.count == 1, let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                    Button("Copy Fingerprint", systemImage: "doc.on.doc") { Platform.copy(row.fingerprint) }
                }
                Button(ids.count == 1 ? "Forget Host Key…" : "Forget Host Keys…", systemImage: "trash", role: .destructive) { pendingForget = KnownHostTableRow.visibleSelection(ids, in: rows) }
            }
        }
        .onDeleteCommand { if !visibleSelection.isEmpty { pendingForget = visibleSelection } }
    }

    private var footer: some View {
        HStack(spacing: TildeSpacing.m) {
            Button("Remove", systemImage: "minus") { pendingForget = visibleSelection }
                .disabled(visibleSelection.isEmpty)
            Text(pins.count == 1 ? "1 host key" : "\(pins.count) host keys")
                .font(TildeFont.caption)
                .foregroundStyle(TildeColor.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TildeSpacing.l)
        .frame(minHeight: 40)
        .background(TildeColor.surface)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No known hosts.", systemImage: "checkmark.shield")
        } description: {
            Text("Host keys appear here after you trust a server on first connect. Pins sync across your devices.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif

/// One pinned key: algorithm badge, fingerprint in mono, last seen date. A conflicted pin is drawn in danger red.
struct KnownHostRow: View {
    let host: KnownHost

    private var isConflicted: Bool { host.status == .conflicted }

    var body: some View {
        HStack(spacing: TildeSpacing.m) {
            TypeBadge(text: KnownHostFormat.algorithmBadge(host.algorithm), tinted: !isConflicted)
                .frame(minWidth: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.fingerprintSHA256)
                    .font(TildeFont.rowSubtitle)
                    .foregroundStyle(isConflicted ? TildeColor.danger : TildeColor.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(isConflicted ? "Conflict · trusted on \(host.trustedOnDevice)" : "Last seen \(KnownHostFormat.date(host.lastSeenAt))")
                    .font(TildeFont.caption)
                    .foregroundStyle(isConflicted ? TildeColor.danger : TildeColor.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isConflicted {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TildeColor.danger).accessibilityHidden(true)
            }
        }
        .frame(minHeight: TildeSpacing.rowHeightMac)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(host.endpoint), \(KnownHostFormat.algorithmBadge(host.algorithm)) key, \(KnownHostFormat.statusTitle(host.status))")
        .accessibilityValue(host.fingerprintSHA256)
        .accessibilityHint("Shows the key details")
    }
}

/// A pinned key in full: fingerprint, algorithm, status, when it was first and last seen, where it was trusted.
struct KnownHostDetailView: View {
    let host: KnownHost
    /// Deletes the pin. The page asks for confirmation itself, because a dialog on the list would sit under this page.
    let forget: (KnownHost) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmsForget = false

    private var isConflicted: Bool { host.status == .conflicted }

    var body: some View {
        Group {
            if host.isDeleted || host.modelContext == nil {
                Color.clear.onAppear { dismiss() }
            } else {
                content
            }
        }
        .background(TildeColor.bg)
    }

    private var content: some View {
        List {
            if isConflicted {
                Section {
                    Banner(
                        .error,
                        headline: "Conflicting host keys",
                        detail: "Another device trusted a different key for this host. Tilde will not connect until you decide which key to trust."
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                FingerprintBlock(tint: isConflicted ? TildeColor.danger : TildeColor.border) {
                    FingerprintRow(
                        label: "Fingerprint",
                        algorithm: KnownHostFormat.algorithmBadge(host.algorithm),
                        fingerprint: host.fingerprintSHA256,
                        tint: isConflicted ? TildeColor.danger : TildeColor.text2
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                detailRow("Host", host.endpoint, mono: true)
                detailRow("Algorithm", host.algorithm, mono: true)
                LabeledContent("Status") {
                    Text(KnownHostFormat.statusTitle(host.status))
                        .foregroundStyle(isConflicted ? TildeColor.danger : TildeColor.ok)
                }
                .listRowBackground(TildeColor.surface2)
                detailRow("First seen", KnownHostFormat.date(host.firstSeenAt))
                detailRow("Last seen", KnownHostFormat.date(host.lastSeenAt))
                if !host.trustedOnDevice.isEmpty { detailRow("Trusted on", host.trustedOnDevice) }
            }
            let history = host.history
            if !history.isEmpty {
                Section {
                    ForEach(Array(history.reversed().enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.fingerprintSHA256)
                                .font(TildeFont.rowSubtitle)
                                .foregroundStyle(TildeColor.text2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("\(KnownHostFormat.algorithmBadge(entry.algorithm)) · replaced \(KnownHostFormat.date(entry.replacedAt))")
                                .font(TildeFont.caption)
                                .foregroundStyle(TildeColor.text3)
                        }
                        .listRowBackground(TildeColor.surface2)
                    }
                } header: {
                    Text("Previous keys").tildeSectionHeader()
                }
            }
            Section {
                Button("Forget Host Key…", role: .destructive) { confirmsForget = true }
                    .listRowBackground(TildeColor.surface2)
            } footer: {
                Text("The next connection to this host asks you to trust its key again.")
            }
        }
        .tildeFormStyle()
        .navigationTitle(host.endpoint)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Forget the host key for \(host.endpoint)?", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget Host Key", role: .destructive) {
                forget(host)
                dismiss()
            }
        } message: {
            Text("The key is removed from all your devices. The next connection to this host asks you to trust its key again.")
        }
    }

    private func detailRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(mono ? TildeFont.mono(13) : nil)
                .foregroundStyle(TildeColor.text2)
                .textSelection(.enabled)
        }
        .listRowBackground(TildeColor.surface2)
    }
}

#Preview("KnownHostsListView") {
    NavigationStack { KnownHostsListView() }
        .modelContainer(ModelContainerFactory.preview())
        .preferredColorScheme(.dark)
}

#Preview("KnownHostsListView, empty") {
    NavigationStack { KnownHostsListView() }
        .modelContainer(try! ModelContainerFactory.make(.inMemory))
        .preferredColorScheme(.dark)
}
