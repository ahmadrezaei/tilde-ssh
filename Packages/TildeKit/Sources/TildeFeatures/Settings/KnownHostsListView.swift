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
