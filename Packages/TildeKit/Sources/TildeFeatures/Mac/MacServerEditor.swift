#if os(macOS)
import AppKit
import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// New / Edit / Save-as server on the Mac: a grouped `Form` with pop-up buttons, a radio group for the sign-in method,
/// checkboxes, a token field for tags and a small table for environment variables. It runs on `ServerEditorModel`, so
/// validation, saving, paste-splitting and Test Connection are the ones the iOS editor uses.
///
/// Return presses "Save & Connect" (see `MacEditorReturn` for when it does not).
public struct MacServerEditor: View {
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
    @State private var envRows: [EnvVarRow] = []
    @State private var showsNewGroup = false
    @State private var newGroupName = ""
    @State private var showsGenerateKey = false
    @State private var confirmsForgetKey = false
    @State private var confirmsDelete = false
    @State private var lastSaveConnects = false
    @State private var tagsFocused = false
    @FocusState private var notesFocused: Bool
    @AppStorage("tilde.macServerEditor.advancedExpanded") private var advancedExpanded = false

    /// - Parameter server: the server to edit, or `nil` to create one.
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
                Color.clear.frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 700)
            }
        }
        .task {
            guard model == nil else { return }
            let created: ServerEditorModel
            if let server { created = ServerEditorModel(editing: server) }
            else if let prefill { created = ServerEditorModel(prefill: prefill, keys: keys) }
            else { created = ServerEditorModel(keys: keys) }
            envRows = EnvVarRow.rows(from: created.envVarsText)
            model = created
        }
    }

    private var actions: ServerActions { ServerActions(context: context, secrets: services.secretStore) }

    // MARK: Sheet

    @ViewBuilder
    private func sheet(_ model: ServerEditorModel) -> some View {
        @Bindable var model = model
        let editingFreeText = tagsFocused || notesFocused
        TildeSheet(model.isNew ? "New Server" : "Edit Server", scrolls: false, idealHeight: 660) {
            VStack(spacing: 0) {
                form($model)
                footer(model)
            }
        } actions: {
            TildeCancelButton { model.cancelTest(); dismiss() }
            TildeActionButton("Save", role: MacEditorReturn.saveRole(environment: model.environment, isEditingFreeText: editingFreeText)) { save(model, connect: false) }
                .disabled(!model.canSave)
            TildeActionButton("Save & Connect", role: MacEditorReturn.saveAndConnectRole(environment: model.environment, isEditingFreeText: editingFreeText)) { save(model, connect: true) }
                .disabled(!model.canSave)
        }
        .banner(model.saveError != nil) {
            if let error = model.saveError { saveErrorBanner(error, model: model) }
        }
        .onChange(of: model.host) { model.splitPastedCommand(using: services.quickConnect, servers: allServers) }
        .onChange(of: envRows) { model.envVarsText = EnvVarRow.text(from: envRows) }
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
        .sheet(isPresented: $showsGenerateKey) {
            GenerateKeySheet { created in model.key = created }
        }
    }

    // MARK: Form

    private func form(_ model: Bindable<ServerEditorModel>) -> some View {
        let m = model.wrappedValue
        return Form {
            Section("Connection") {
                TextField("Name", text: model.name, prompt: Text(m.namePlaceholder).foregroundStyle(TildeColor.text3))
                LabeledContent("Host") {
                    HStack(spacing: 6) {
                        TextField("Host", text: model.host, prompt: Text("hostname or IP").foregroundStyle(TildeColor.text3))
                            .labelsHidden()
                        Text(":").foregroundStyle(TildeColor.text3)
                        TextField("Port", text: model.portText, prompt: Text("22").foregroundStyle(TildeColor.text3))
                            .labelsHidden()
                            .frame(width: 60)
                    }
                    .tildeMono(13)
                }
                issueText(m.showsValidation ? m.issue(for: .host) ?? m.issue(for: .port) : nil)
                TextField("Username", text: model.username, prompt: Text(TildeSettings.currentDefaultUser).foregroundStyle(TildeColor.text3))
                    .textContentType(.username)
            }

            Section("Authentication") {
                Picker("Method", selection: model.auth) {
                    Text("Key").tag(AuthMethod.key)
                    Text("Password").tag(AuthMethod.password)
                    Text("Ask each time").tag(AuthMethod.passwordPrompt)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                authDetail(model)
            }

            Section("Organize") {
                Picker("Environment", selection: model.environment) {
                    ForEach(ServerEnvironment.allCases, id: \.self) { environment in
                        Label { Text(Self.title(environment)) } icon: { Self.dot(for: environment) }.tag(environment)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent("Group") {
                    HStack(spacing: 8) {
                        Picker("Group", selection: model.group) {
                            Text("None").tag(ServerGroup?.none)
                            ForEach(groups) { group in Label(group.name, systemImage: group.symbol).tag(Optional(group)) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Button("New Group…") { showsNewGroup = true }
                    }
                }
                LabeledContent("Tags") {
                    TildeTokenField(tokens: model.tags, prompt: "Add tag", suggestions: allTags.map(\.name), isFocused: $tagsFocused)
                }
                Toggle("Favorite", isOn: model.isFavorite).toggleStyle(.checkbox)
            }

            Section {
                Toggle("Auto-attach tmux", isOn: model.autoTmux).toggleStyle(.checkbox)
                if m.autoTmux {
                    TextField("tmux session", text: model.tmuxSessionName, prompt: Text("tilde").foregroundStyle(TildeColor.text3)).tildeMono(13)
                }
                TextField("Startup command", text: model.startupCommand, prompt: Text("tmux new -A -s tilde").foregroundStyle(TildeColor.text3)).tildeMono(13)
                Picker("TERM", selection: model.termType) {
                    ForEach(m.termChoices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    advanced(model)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(TildeColor.bg)
    }

    @ViewBuilder
    private func authDetail(_ model: Bindable<ServerEditorModel>) -> some View {
        let m = model.wrappedValue
        switch m.auth {
        case .key:
            LabeledContent("Key") {
                HStack(spacing: 8) {
                    Picker("Key", selection: model.key) {
                        Text("None").tag(SSHKeyRecord?.none)
                        ForEach(keys) { key in Text(Self.label(for: key)).tag(Optional(key)) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Button("Generate…") { showsGenerateKey = true }
                }
            }
            issueText(m.showsValidation ? m.issue(for: .key) : nil)
        case .password:
            SecureField("Password", text: model.password, prompt: Text(m.hasSavedPassword ? "Saved. Type to replace." : "").foregroundStyle(TildeColor.text3))
                .textContentType(.password)
            issueText(m.issue(for: .password))
            note("Stored in iCloud Keychain, never in the synced database.")
        case .passwordPrompt:
            note("Nothing is stored. You are asked at every connection.")
        }
    }

    @ViewBuilder
    private func advanced(_ model: Bindable<ServerEditorModel>) -> some View {
        let m = model.wrappedValue
        Picker("Jump host", selection: model.jump) {
            Text("None").tag(Server?.none)
            ForEach(allServers.filter { $0.id != m.original?.id }) { Text(ServerMapper.displayName($0)).tag(Optional($0)) }
        }
        .pickerStyle(.menu)
        issueText(m.showsValidation ? m.issue(for: .jump) : nil)

        LabeledContent("Keep-alive") {
            HStack(spacing: 8) {
                Text(m.keepAliveSeconds == 0 ? "off" : "\(m.keepAliveSeconds) s").tildeMono(13).monospacedDigit()
                Stepper("Keep-alive", value: model.keepAliveSeconds, in: 0...300, step: 5).labelsHidden()
            }
        }

        environmentVariables(m)

        VStack(alignment: .leading, spacing: 4) {
            Text("Notes").foregroundStyle(TildeColor.text2)
            TextEditor(text: model.notes)
                .tildeMono(13)
                .focused($notesFocused)
                .frame(height: 56)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(TildeColor.surface2, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Notes")
        }

        if !m.isNew {
            LabeledContent("Danger zone") {
                HStack(spacing: 8) {
                    Button("Forget Host Key…", role: .destructive) { confirmsForgetKey = true }
                    Button("Delete Server…", role: .destructive) { confirmsDelete = true }
                }
            }
        }
    }

    private func environmentVariables(_ m: ServerEditorModel) -> some View {
        let duplicates = EnvVarRow.duplicateKeys(in: envRows)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Environment variables").foregroundStyle(TildeColor.text2)
                Spacer()
                Button { envRows.append(EnvVarRow()) } label: { Label("Add Variable", systemImage: "plus") }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.borderless)
            }
            if !envRows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text("Name").tildeText(11, weight: .semibold, relativeTo: .caption).foregroundStyle(TildeColor.text3)
                        Text("Value").tildeText(11, weight: .semibold, relativeTo: .caption).foregroundStyle(TildeColor.text3)
                        Color.clear.frame(width: 18, height: 1)
                    }
                    ForEach($envRows) { $row in
                        GridRow {
                            TextField("Name", text: $row.key, prompt: Text("LANG").foregroundStyle(TildeColor.text3))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            TextField("Value", text: $row.value, prompt: Text("en_US.UTF-8").foregroundStyle(TildeColor.text3))
                                .textFieldStyle(.roundedBorder)
                            Button { envRows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove variable")
                        }
                    }
                }
                .tildeMono(12)
            }
            issueText(m.issue(for: .envVars))
            if !duplicates.isEmpty {
                note("Repeated: \(duplicates.sorted().joined(separator: ", ")). The last one wins.")
            }
            note("Servers may reject these (AcceptEnv).")
        }
    }

    // MARK: Footer

    /// The `ssh …` line the form describes, and Test Connection with its result.
    private func footer(_ model: ServerEditorModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(TildeColor.border)
            HStack(spacing: 8) {
                Text(model.sshPreview)
                    .tildeMono(12, relativeTo: .caption)
                    .foregroundStyle(TildeColor.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("The equivalent OpenSSH command")
                Button { Platform.copy(model.sshPreview) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy the ssh command")
                    .accessibilityLabel("Copy ssh command")
                Button("Test Connection") { model.test(services: services, coordinator: coordinator) }
                    .disabled(model.testState == .running)
                if model.testState == .running { ProgressView().controlSize(.small) }
            }
            testResult(model.testState)
        }
        .padding(.horizontal, TildeSheetMetrics.padding)
        .padding(.bottom, 10)
        .background(TildeColor.bg)
    }

    @ViewBuilder
    private func testResult(_ state: ServerEditorModel.TestState) -> some View {
        switch state {
        case .idle, .running:
            EmptyView()
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.ok)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let copy):
            VStack(alignment: .leading, spacing: 2) {
                Label(copy.headline, systemImage: "xmark.octagon.fill").tildeText(13, weight: .semibold, relativeTo: .subheadline).foregroundStyle(TildeColor.danger)
                if let detail = copy.detail { Text(detail).tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.text2) }
            }
            .fixedSize(horizontal: false, vertical: true)
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

    // MARK: Pieces

    @ViewBuilder
    private func issueText(_ issue: String?) -> some View {
        if let issue { TildeIssueText(issue) }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .tildeText(12, relativeTo: .caption)
            .foregroundStyle(TildeColor.text3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// `iphone-ed25519 · ED25519 · …Vw0`
    private static func label(for key: SSHKeyRecord) -> String {
        "\(key.name) · \(key.typeBadge) · …\(key.fingerprintSHA256.suffix(3))"
    }

    static func title(_ environment: ServerEnvironment) -> String {
        switch environment {
        case .none: "None"
        case .dev: "Development"
        case .staging: "Staging"
        case .prod: "Production"
        case .lab: "Lab"
        }
    }

    /// A coloured dot for the pop-up. A menu draws template images in the menu text colour, so the image is a
    /// non-template one with its own colour.
    static func dot(for environment: ServerEnvironment) -> Image {
        let color = NSColor(EnvTone(environment).color)
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return Image(systemName: "circle.fill")
        }
        symbol.isTemplate = false
        return Image(nsImage: symbol)
    }
}

#Preview("MacServerEditor: new") {
    TildePreviewHost(openSession: false) { _ in MacServerEditor() }
}
#endif
