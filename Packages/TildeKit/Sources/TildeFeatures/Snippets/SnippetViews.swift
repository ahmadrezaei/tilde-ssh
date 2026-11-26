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

    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    /// On the Mac the snippet manager is a sheet: the shared scaffold, a search field, and New Snippet in the action bar.
    private var macBody: some View {
        TildeSheet("Snippets", subtitle: snippets.isEmpty ? nil : "\(snippets.count) saved", scrolls: false, idealHeight: 600) {
            VStack(spacing: 0) {
                HStack(spacing: TildeSpacing.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(TildeColor.text3).accessibilityHidden(true)
                    TextField("", text: $searchText, prompt: Text("Search snippets").foregroundStyle(TildeColor.text3))
                        .textFieldStyle(.plain)
                        .tildeMono(15)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Search snippets")
                }
                .padding(.horizontal, TildeSheetMetrics.padding)
                .frame(minHeight: 48)
                .background(TildeColor.surface)
                Divider().overlay(TildeColor.border)
                if snippets.isEmpty {
                    EmptyState("No snippets.", message: "Save the commands you type all the time. Use <name> for parts you fill in.") {
                        Button("Add snippet") { navigator.present(.newSnippet) }.buttonStyle(.tildeSheetPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: TildeSpacing.l) {
                            if filtered.isEmpty {
                                ContentUnavailableView.search(text: searchText).frame(maxWidth: .infinity)
                            }
                            let favorites = filtered.filter(\.isFavorite)
                            if !favorites.isEmpty { macSection("Favorites", favorites) }
                            ForEach(folderNames, id: \.self) { folder in
                                macSection(folder, filtered.filter { $0.folder == folder })
                            }
                            let loose = filtered.filter { ($0.folder ?? "").isEmpty }
                            if !loose.isEmpty { macSection(folderNames.isEmpty ? "Snippets" : "Other", loose) }
                        }
                        .padding(TildeSheetMetrics.padding)
                    }
                    .background(TildeColor.bg)
                }
            }
        } actions: {
            EmptyView()
        }
        .headerAccessory {
            Button { navigator.present(.newSnippet) } label: { Label("New Snippet", systemImage: "plus") }
                .buttonStyle(.tildeSheetSecondary)
        }
        // The window's sheet host adds its own Done button in the sheet's bottom bar.
        .actionBar(false)
        .toolbar(.hidden, for: .windowToolbar)
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

    private func macSection(_ title: String, _ items: [Snippet]) -> some View {
        TildeFormSection(title) {
            ForEach(items) { snippet in
                row(snippet).padding(.vertical, 6)
            }
        }
    }
    #endif

    private var iosBody: some View {
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
        TildeSheet(snippet == nil ? "New Snippet" : "Edit Snippet", idealHeight: 640) {
            VStack(alignment: .leading, spacing: TildeSpacing.l) {
                TildeFormSection(footer: "Wrap a part in <angle brackets>, like <unit>, to fill it in when you insert the snippet.") {
                    TildeTextRow("Name", prompt: "service status", text: $name, isMono: false)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command").tildeText(13, relativeTo: .footnote).foregroundStyle(TildeColor.text2).padding(.top, 8)
                        TextEditor(text: $command)
                            .tildeMono(14)
                            .frame(minHeight: 96)
                            .scrollContentBackground(.hidden)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .accessibilityLabel("Command")
                            .overlay(alignment: .topLeading) {
                                if command.isEmpty {
                                    Text("systemctl status <unit>")
                                        .tildeMono(14)
                                        .foregroundStyle(TildeColor.text3)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.bottom, 6)
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
                }
                TildeFormSection(footer: runsOnInsert ? "Presses Return after typing. Multi-line snippets ask first on production servers." : "Types the command so you can edit it before pressing Return.") {
                    TildeFieldRow("When inserted") {
                        Picker("When inserted", selection: $runsOnInsert) {
                            Text("Type only").tag(false)
                            Text("Type and run").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        #if os(macOS)
                        .fixedSize()
                        #endif
                    }
                    TildeTextRow("Folder", prompt: "optional", text: $folder, isMono: false)
                    TildeToggleRow("Favorite", isOn: $isFavorite)
                    TildePickerRow("Available on", selection: $scopeServer) {
                        Text("All servers").tag(Server?.none)
                        ForEach(servers) { Text(ServerMapper.displayName($0)).tag(Optional($0)) }
                    }
                }
                if snippet != nil {
                    TildeFormSection {
                        TildeActionRow("Delete snippet", tone: .danger) { confirmsDelete = true }
                    }
                }
            }
        } actions: {
            TildeCancelButton { dismiss() }
            TildeDefaultButton("Save", action: save).disabled(!canSave)
        }
        .confirmationDialog("Delete this snippet?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Snippet", role: .destructive) {
                if let snippet { context.delete(snippet); try? context.save() }
                dismiss()
            }
        }
        .onAppear(perform: load)
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
        TildeSheet(snippet.name, subtitle: "Fill in the parts to insert", size: .compact, scrolls: false) {
            VStack(alignment: .leading, spacing: TildeSpacing.l) {
                TildeFormSection {
                    ForEach(names, id: \.self) { name in
                        TildeFieldRow(name) {
                            TildeTextField(name, prompt: "value", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                                .focused($focused, equals: name)
                                .submitLabel(.go)
                                .onSubmit { onInsert(values) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Result").tildeSectionHeader()
                    Text(SnippetTemplate.fill(snippet.command, values: values))
                        .tildeMono(12, relativeTo: .caption)
                        .foregroundStyle(TildeColor.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 4)
            }
            .padding(TildeSheetMetrics.padding)
        } actions: {
            TildeCancelButton { dismiss() }
            TildeDefaultButton(snippet.runOnInsert ? "Insert & Run" : "Insert") { onInsert(values) }
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
