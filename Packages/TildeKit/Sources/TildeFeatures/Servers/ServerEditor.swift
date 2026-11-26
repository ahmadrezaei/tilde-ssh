import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// Add / Edit server (design section 4.2): one scrolling grouped form with dense rows. Save is enabled once the
/// form validates; Save & Connect is the primary button in the bottom bar.
public struct ServerEditor: View {
    private let server: Server?
    private let prefill: SaveServerRequest?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Environment(SessionCoordinator.self) private var coordinator
    @Environment(AppNavigator.self) private var navigator

    @Query(sort: \Server.name) private var allServers: [Server]
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    @Query(sort: [SortDescriptor(\ServerGroup.sortIndex), SortDescriptor(\ServerGroup.name)]) private var groups: [ServerGroup]
    @Query(sort: \Tag.name) private var allTags: [Tag]

    @State private var model: ServerEditorModel?
    @State private var showsNewGroup = false
    @State private var newGroupName = ""
    @State private var confirmsForgetKey = false
    @State private var confirmsDelete = false
    @State private var showsAdvanced = false
    @State private var lastSaveConnects = false

    /// - Parameters:
    ///   - server: the server to edit, or `nil` to create one.
    ///   - prefill: a Quick Connect session to save as a server.
    public init(server: Server? = nil) {
        self.server = server
        self.prefill = nil
    }

    init(prefill: SaveServerRequest) {
        self.server = nil
        self.prefill = prefill
    }

    public var body: some View {
        Group {
            if let model {
                sheet(model)
            } else {
                Color.clear.frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 660)
            }
        }
        .task {
            guard model == nil else { return }
            if let server { model = ServerEditorModel(editing: server) }
            else if let prefill { model = ServerEditorModel(prefill: prefill, keys: keys) }
            else { model = ServerEditorModel(keys: keys) }
        }
    }

    // MARK: Form

    @ViewBuilder
    private func sheet(_ model: ServerEditorModel) -> some View {
        @Bindable var model = model
        TildeSheet(model.isNew ? "New Server" : "Edit Server", idealHeight: 660) {
            VStack(alignment: .leading, spacing: TildeSpacing.l) {
                connectionSection($model)
                authenticationSection($model)
                organizeSection($model)
                advancedSection($model)
                testSection(model)
                if !model.isNew { dangerSection(model) }
            }
        } actions: {
            TildeCancelButton { model.cancelTest(); dismiss() }
            Button("Save") { save(model, connect: false) }
                .buttonStyle(.tildeSheetSecondary)
                .disabled(!model.canSave)
            Button("Save & Connect") { save(model, connect: true) }
                .buttonStyle(.tildeSheetPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
        }
        .banner(model.saveError != nil) {
            if let error = model.saveError { saveErrorBanner(error, model: model) }
        }
        .onChange(of: model.host) { model.splitPastedCommand(using: services.quickConnect, servers: allServers) }
        .alert("New Group", isPresented: $showsNewGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") {
                model.group = actions.createGroup(named: newGroupName)
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
        .confirmationDialog("Forget the host key for \(model.trimmedHost)?", isPresented: $confirmsForgetKey, titleVisibility: .visible) {
            Button("Forget Host Key", role: .destructive) { if let server = model.original { actions.forgetHostKey(for: server) } }
        } message: {
            Text("The next connection will ask whether to trust the key it presents.")
        }
        .confirmationDialog("Delete \(model.name.isEmpty ? model.trimmedHost : model.name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete Server", role: .destructive) {
                if let server = model.original { actions.delete(server) }
                dismiss()
            }
        } message: {
            Text("This removes it from all your devices and deletes its saved password.")
        }
    }

    private var actions: ServerActions { ServerActions(context: context, secrets: services.secretStore) }

    private func connectionSection(_ model: Bindable<ServerEditorModel>) -> some View {
        let m = model.wrappedValue
        return TildeFormSection("Connection") {
            TildeTextRow("Name", prompt: m.namePlaceholder, text: model.name)
            TildeTextRow("Host", prompt: "hostname or IP", text: model.host, issue: m.showsValidation ? m.issue(for: .host) : nil)
                #if os(iOS)
                .keyboardType(.URL)
                #endif
            TildeTextRow("Port", prompt: "22", text: model.portText, issue: m.showsValidation ? m.issue(for: .port) : nil)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            TildeTextRow("Username", prompt: TildeSettings.currentDefaultUser, text: model.username)
        }
    }

    private func authenticationSection(_ model: Bindable<ServerEditorModel>) -> some View {
        let m = model.wrappedValue
        let footer: String? = m.isPasswordAuth
            ? (m.asksEveryTime ? "Nothing is stored. You are asked at every connection." : "Stored in iCloud Keychain, never in the synced database.")
            : nil
        return TildeFormSection("Authentication", footer: footer) {
            Picker("Method", selection: Binding(
                get: { m.auth == .key ? AuthChoice.key : .password },
                set: { choice in
                    switch choice {
                    case .key: m.auth = .key
                    case .password: if m.auth == .key { m.auth = m.hasSavedPassword || !m.password.isEmpty ? .password : .passwordPrompt }
                    }
                }
            )) {
                Text("Key").tag(AuthChoice.key)
                Text("Password").tag(AuthChoice.password)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            #if os(macOS)
            .fixedSize()
            #endif

            if m.auth == .key {
                KeyPicker(selection: model.key, issue: m.showsValidation ? m.issue(for: .key) : nil)
            } else {
                TildeToggleRow("Ask every time", isOn: model.asksEveryTime)
                if !m.asksEveryTime {
                    TildeTextRow("Password", prompt: m.hasSavedPassword ? "Saved. Type to replace." : "Password", text: model.password,
                                 isSecure: true, issue: m.issue(for: .password))
                }
            }
        }
    }

    private func organizeSection(_ model: Bindable<ServerEditorModel>) -> some View {
        TildeFormSection("Organize") {
            TildeFieldRow("Environment") { EnvironmentPicker(selection: model.environment) }
            TildePickerRow("Group", selection: model.group) {
                Text("None").tag(ServerGroup?.none)
                ForEach(groups) { group in Label(group.name, systemImage: group.symbol).tag(Optional(group)) }
            }
            TildeActionRow("New group…", systemImage: "folder.badge.plus") { showsNewGroup = true }
            TagTokenField(tags: model.tags, suggestions: allTags.map(\.name))
            TildeToggleRow("Favorite", isOn: model.isFavorite)
        }
    }

    private func advancedSection(_ model: Bindable<ServerEditorModel>) -> some View {
        let m = model.wrappedValue
        return VStack(alignment: .leading, spacing: TildeSpacing.l) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showsAdvanced.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Advanced").tildeText(14, weight: .medium, relativeTo: .body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(TildeColor.text2)
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsAdvanced ? "Expanded" : "Collapsed")

            if showsAdvanced {
                TildeFormSection {
                    TildePickerRow("Jump host", selection: model.jump, issue: m.showsValidation ? m.issue(for: .jump) : nil) {
                        Text("None").tag(Server?.none)
                        ForEach(allServers.filter { $0.id != m.original?.id }) { Text(ServerMapper.displayName($0)).tag(Optional($0)) }
                    }
                    TildeTextRow("Startup", prompt: "tmux new -A -s tilde", text: model.startupCommand)
                    TildeToggleRow("Auto-attach tmux", isOn: model.autoTmux)
                    if m.autoTmux {
                        TildeTextRow("tmux session", prompt: "tilde", text: model.tmuxSessionName)
                    }
                    TildeFieldRow("Keep-alive") {
                        HStack(spacing: 10) {
                            Text(m.keepAliveSeconds == 0 ? "off" : "\(m.keepAliveSeconds) s")
                                .tildeMono(13)
                                .foregroundStyle(TildeColor.text)
                            Stepper("Keep-alive", value: model.keepAliveSeconds, in: 0...300, step: 5).labelsHidden()
                        }
                    }
                    TildeTextRow("TERM", prompt: "xterm-256color", text: model.termType)
                }
                TildeFormSection(
                    "Environment variables",
                    footer: m.showsValidation ? (m.issue(for: .envVars) ?? "Servers may reject these (AcceptEnv).") : "KEY=value, one per line. Servers may reject these (AcceptEnv).",
                    footerTint: m.showsValidation && m.issue(for: .envVars) != nil ? TildeColor.danger : TildeColor.text3
                ) {
                    TextEditor(text: model.envVarsText)
                        .tildeMono(13)
                        .frame(minHeight: 72)
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .padding(.vertical, 6)
                        .accessibilityLabel("Environment variables")
                }
                TildeFormSection("Notes") {
                    TextEditor(text: model.notes)
                        .tildeMono(13)
                        .frame(minHeight: 72)
                        .scrollContentBackground(.hidden)
                        .padding(.vertical, 6)
                        .accessibilityLabel("Notes")
                }
            }
        }
    }

    private func testSection(_ model: ServerEditorModel) -> some View {
        TildeFormSection {
            TildeActionRow("Test connection", systemImage: "bolt.horizontal", action: { model.test(services: services, coordinator: coordinator) }) {
                if model.testState == .running { ProgressView().controlSize(.small) }
            }
            .disabled(model.testState == .running)
            switch model.testState {
            case .idle, .running:
                EmptyView()
            case .success(let text):
                Label(text, systemImage: "checkmark.circle.fill")
                    .tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.ok)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
            case .failure(let copy):
                VStack(alignment: .leading, spacing: 4) {
                    Label(copy.headline, systemImage: "xmark.octagon.fill").tildeText(14, weight: .semibold, relativeTo: .subheadline).foregroundStyle(TildeColor.danger)
                    if let detail = copy.detail { Text(detail).tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.text2) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
            }
        }
    }

    private func dangerSection(_ model: ServerEditorModel) -> some View {
        TildeFormSection("Danger zone") {
            TildeActionRow("Forget host key", tone: .danger) { confirmsForgetKey = true }
            TildeActionRow("Delete server", tone: .danger) { confirmsDelete = true }
        }
    }

    // MARK: Actions

    private func save(_ model: ServerEditorModel, connect: Bool) {
        model.cancelTest()
        lastSaveConnects = connect
        guard let saved = model.save(context: context, secrets: services.secretStore) else { return }
        dismiss()
        if connect { navigator.open(ServerMapper.snapshot(saved)) }
    }

    /// The editor stays open when the Keychain refuses the password; the user retries or stops saving one.
    private func saveErrorBanner(_ error: ServerEditorModel.SaveError, model: ServerEditorModel) -> some View {
        Banner(
            .error, headline: error.message,
            actions: [
                .init("Try Again") { save(model, connect: lastSaveConnects) },
                .init("Ask Every Time Instead") {
                    model.useAskEveryTime()
                    save(model, connect: lastSaveConnects)
                },
            ]
        )
    }
}

private enum AuthChoice: Hashable { case key, password }

/// None / Dev / Staging / Prod / Lab, with the environment colour dots (Prod is red when selected).
struct EnvironmentPicker: View {
    @Binding var selection: ServerEnvironment

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ServerEnvironment.allCases, id: \.self) { env in
                let tone = EnvTone(env)
                let isOn = env == selection
                Button { selection = env } label: {
                    HStack(spacing: 4) {
                        if env != .none { Circle().fill(tone.color).frame(width: 6, height: 6) }
                        Text(title(env)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .tildeText(11, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(isOn ? (env == .prod ? TildeColor.danger : TildeColor.text) : TildeColor.text2)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(isOn ? (env == .prod ? TildeColor.danger.opacity(0.2) : TildeColor.surface3) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tone == .none ? "No environment" : tone.accessibilityName)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(TildeColor.surface3.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func title(_ env: ServerEnvironment) -> String {
        switch env {
        case .none: "None"
        case .dev: "Dev"
        case .staging: "Staging"
        case .prod: "Prod"
        case .lab: "Lab"
        }
    }
}

/// Tags as removable chips plus a field that commits on return or comma.
struct TagTokenField: View {
    @Binding var tags: [String]
    let suggestions: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Button { tags.removeAll { $0 == tag } } label: {
                                HStack(spacing: 4) {
                                    Text(tag)
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .tildeMono(11, weight: .semibold, relativeTo: .caption)
                                .foregroundStyle(TildeColor.accent)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(TildeColor.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Tag \(tag)")
                            .accessibilityHint("Removes the tag")
                        }
                    }
                }
                .padding(.top, 8)
            }
            TildeFieldRow("Tags") {
                TildeTextField("Tags", prompt: "add tag", text: $draft)
                    .onSubmit(commit)
                    .onChange(of: draft) { if draft.hasSuffix(",") { commit() } }
            }
            let matches = suggestions.filter { s in !tags.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) && (draft.isEmpty || s.localizedCaseInsensitiveContains(draft)) }.prefix(6)
            if !matches.isEmpty && !draft.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(Array(matches), id: \.self) { s in TagChip(s, isOn: false) { draft = s; commit() } } }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func commit() {
        let name = draft.trimmingCharacters(in: CharacterSet(charactersIn: ", ").union(.whitespaces))
        draft = ""
        guard !name.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        tags.append(name)
    }
}

#Preview("ServerEditor: new") {
    TildePreviewHost(openSession: false) { _ in ServerEditor() }
}

#Preview("ServerEditor: edit") {
    TildePreviewHost(openSession: false) { _ in EditPreview() }
}

private struct EditPreview: View {
    @Query(sort: \Server.name) private var servers: [Server]
    var body: some View {
        if let server = servers.first(where: { $0.name == "prod-api-01" }) { ServerEditor(server: server) } else { Color.clear }
    }
}
