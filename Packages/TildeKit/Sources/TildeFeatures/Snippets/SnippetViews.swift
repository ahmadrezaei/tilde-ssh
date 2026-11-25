import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// Snippets (design section 3.1): saved commands inserted, or inserted and run, into the active session.
public struct SnippetList: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    @Query(sort: [SortDescriptor(\Snippet.sortIndex), SortDescriptor(\Snippet.name)]) private var snippets: [Snippet]
    @State private var searchText = ""
    @State private var pendingFill: SnippetSnapshot?
    @State private var pendingDelete: Snippet?

    public init() {}

    public var body: some View {
        List {
            if filtered.isEmpty && !snippets.isEmpty {
                ContentUnavailableView.search(text: searchText).listRowBackground(Color.clear)
            }
            let favorites = filtered.filter(\.isFavorite)
            if !favorites.isEmpty {
                Section { ForEach(favorites) { row($0) } } header: { SectionHeader("Favorites", systemImage: "star.fill", count: favorites.count) }
            }
            ForEach(folderNames, id: \.self) { folder in
                let items = filtered.filter { $0.folder == folder }
                Section { ForEach(items) { row($0) } } header: { SectionHeader(folder, systemImage: "folder", count: items.count) }
            }
            let loose = filtered.filter { ($0.folder ?? "").isEmpty }
            if !loose.isEmpty {
                Section {
                    ForEach(loose) { row($0) }
                } header: {
                    SectionHeader(folderNames.isEmpty ? "Snippets" : "Other", count: loose.count)
                }
            }
        }
        .tildeList()
        .navigationTitle("Snippets")
        .searchable(text: $searchText, prompt: "Search snippets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { navigator.present(.newSnippet) } label: { Image(systemName: "plus") }.accessibilityLabel("New snippet")
            }
        }
        .overlay {
            if snippets.isEmpty {
                EmptyState("No snippets.", message: "Save the commands you type all the time. Use <name> for parts you fill in.") {
                    Button("Add snippet") { navigator.present(.newSnippet) }.buttonStyle(.tildePrimary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TildeColor.bg)
            }
        }
        .sheet(item: $pendingFill) { snippet in
            SnippetFillSheet(snippet: snippet) { values in
                coordinator.insert(snippet, values: values, in: navigator.windowID)
                pendingFill = nil
            }
        }
        .confirmationDialog("Delete \"\(pendingDelete?.name ?? "")\"?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Snippet", role: .destructive) {
                if let snippet = pendingDelete { context.delete(snippet); try? context.save() }
                pendingDelete = nil
            }
        }
    }

    private var filtered: [Snippet] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return snippets }
        return snippets.filter { Fuzzy.score(q, in: $0.name) != nil || $0.command.localizedCaseInsensitiveContains(q) }
    }

    private var folderNames: [String] {
        Array(Set(filtered.compactMap(\.folder).filter { !$0.isEmpty })).sorted()
    }

    private var canInsert: Bool { navigator.selectedTab?.isConnected == true }

    private func insert(_ snippet: Snippet) {
        let snap = snippet.snapshot
        if SnippetTemplate.placeholders(in: snap.command).isEmpty {
            coordinator.insert(snap, in: navigator.windowID)
        } else {
            pendingFill = snap
        }
    }

    private func row(_ snippet: Snippet) -> some View {
        Button { navigator.present(.editSnippet(snippet.id)) } label: { SnippetRow(snippet: snippet) }
            .buttonStyle(.plain)
            .tildeRowBackground()
            .swipeActions(edge: .leading) {
                if canInsert {
                    Button { insert(snippet) } label: { Label("Insert", systemImage: "arrow.down.to.line") }.tint(TildeColor.accentStrong)
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { pendingDelete = snippet } label: { Label("Delete", systemImage: "trash") }
                Button { snippet.isFavorite.toggle(); try? context.save() } label: { Label("Favorite", systemImage: "star") }.tint(TildeColor.warn)
            }
            .contextMenu {
                if canInsert { Button { insert(snippet) } label: { Label("Insert in Session", systemImage: "arrow.down.to.line") } }
                Button { Platform.copy(snippet.command) } label: { Label("Copy Command", systemImage: "doc.on.doc") }
                Button { snippet.isFavorite.toggle(); try? context.save() } label: {
                    Label(snippet.isFavorite ? "Remove from Favorites" : "Favorite", systemImage: snippet.isFavorite ? "star.slash" : "star")
                }
                Button { navigator.present(.editSnippet(snippet.id)) } label: { Label("Edit…", systemImage: "pencil") }
                Divider()
                Button(role: .destructive) { pendingDelete = snippet } label: { Label("Delete…", systemImage: "trash") }
            }
    }
}

struct SnippetRow: View {
    let snippet: Snippet

    var body: some View {
        HStack(spacing: TildeSpacing.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snippet.name).tildeText(15, weight: .semibold, relativeTo: .body).foregroundStyle(TildeColor.text).lineLimit(1)
                Text(snippet.command).tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            if snippet.scopeServer != nil {
                Image(systemName: "server.rack").font(.system(size: 11)).foregroundStyle(TildeColor.text3).accessibilityLabel("Server-specific")
            }
            if snippet.runsOnInsert {
                Image(systemName: "return").font(.system(size: 11, weight: .bold)).foregroundStyle(TildeColor.accent).accessibilityLabel("Runs on insert")
            }
        }
        .tildeRowHeight()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editor

/// Name, command (with `<placeholder>` detection), run mode, folder, favorite, scope.
public struct SnippetEditor: View {
    private let snippet: Snippet?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Server.name) private var servers: [Server]

    @State private var name = ""
    @State private var command = ""
    @State private var runsOnInsert = false
    @State private var folder = ""
    @State private var isFavorite = false
    @State private var scopeServer: Server?
    @State private var loaded = false
    @State private var confirmsDelete = false

    public init(snippet: Snippet? = nil) { self.snippet = snippet }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command").tildeText(13, relativeTo: .footnote).foregroundStyle(TildeColor.text2)
                        TextEditor(text: $command)
                            .tildeMono(14)
                            .frame(minHeight: 96)
                            .scrollContentBackground(.hidden)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    if !placeholders.isEmpty {
                        HStack(spacing: 6) {
                            Text("Asks for").tildeText(12, relativeTo: .caption).foregroundStyle(TildeColor.text3)
                            ForEach(placeholders, id: \.self) { name in
                                Text(name).tildeMono(11, weight: .semibold, relativeTo: .caption).foregroundStyle(TildeColor.accent)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(TildeColor.accentSoft, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                } footer: {
                    Text("Wrap a part in <angle brackets>, like <unit>, to fill it in when you insert the snippet.")
                }
                Section {
                    Picker("When inserted", selection: $runsOnInsert) {
                        Text("Type only").tag(false)
                        Text("Type and run").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Folder (optional)", text: $folder)
                    Toggle("Favorite", isOn: $isFavorite)
                    Picker("Available on", selection: $scopeServer) {
                        Text("All servers").tag(Server?.none)
                        ForEach(servers) { Text(ServerMapper.displayName($0)).tag(Optional($0)) }
                    }
                } footer: {
                    Text(runsOnInsert ? "Presses Return after typing. Multi-line snippets ask first on production servers." : "Types the command so you can edit it before pressing Return.")
                }
                if snippet != nil {
                    Section { Button("Delete snippet", role: .destructive) { confirmsDelete = true } }
                }
            }
            .scrollContentBackground(.hidden)
            .background(TildeColor.bg)
            .navigationTitle(snippet == nil ? "New Snippet" : "Edit Snippet")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .confirmationDialog("Delete this snippet?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Snippet", role: .destructive) {
                    if let snippet { context.delete(snippet); try? context.save() }
                    dismiss()
                }
            }
        }
        .onAppear(perform: load)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }

    private var placeholders: [String] { SnippetTemplate.placeholders(in: command) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let snippet else { return }
        name = snippet.name
        command = snippet.command
        runsOnInsert = snippet.runsOnInsert
        folder = snippet.folder ?? ""
        isFavorite = snippet.isFavorite
        scopeServer = snippet.scopeServer
    }

    private func save() {
        let model = snippet ?? Snippet()
        model.name = name.trimmingCharacters(in: .whitespaces)
        model.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        model.runModeRaw = runsOnInsert ? "insertAndReturn" : "insert"
        model.folder = folder.trimmingCharacters(in: .whitespaces).isEmpty ? nil : folder.trimmingCharacters(in: .whitespaces)
        model.isFavorite = isFavorite
        model.scopeServer = scopeServer
        model.updatedAt = .now
        if snippet == nil {
            let all = (try? context.fetch(FetchDescriptor<Snippet>())) ?? []
            model.sortIndex = FractionalOrder.next(after: all.map(\.sortIndex))
            context.insert(model)
        }
        try? context.save()
        dismiss()
    }
}

// MARK: - Fill placeholders

/// Asks for each `<placeholder>` before a snippet is typed into the session.
struct SnippetFillSheet: View {
    let snippet: SnippetSnapshot
    let onInsert: ([String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @FocusState private var focused: String?

    var body: some View {
        let names = SnippetTemplate.placeholders(in: snippet.command)
        NavigationStack {
            Form {
                Section {
                    ForEach(names, id: \.self) { name in
                        LabeledContent(name) {
                            TextField("value", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                                .tildeMono(15)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                                .focused($focused, equals: name)
                                .submitLabel(.go)
                                .onSubmit { onInsert(values) }
                        }
                    }
                } footer: {
                    Text(SnippetTemplate.fill(snippet.command, values: values)).tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.text2)
                }
            }
            .scrollContentBackground(.hidden)
            .background(TildeColor.bg)
            .navigationTitle(snippet.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(snippet.runOnInsert ? "Insert & Run" : "Insert") { onInsert(values) } }
            }
        }
        .presentationDetents([.medium])
        .onAppear { focused = names.first }
    }
}

#Preview("SnippetList") {
    TildePreviewHost { _ in NavigationStack { SnippetList() } }
}

#Preview("SnippetEditor") {
    TildePreviewHost(openSession: false) { _ in SnippetEditor() }
}
