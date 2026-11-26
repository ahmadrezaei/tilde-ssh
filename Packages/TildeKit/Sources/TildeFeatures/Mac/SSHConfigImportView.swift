import SwiftUI
import TildeCore
import TildeDesign
import UniformTypeIdentifiers

/// Imports servers from an OpenSSH client config (`~/.ssh/config`).
///
/// The view is pure UI plus callbacks: it reads a file the user picks (the App Sandbox only allows
/// user-selected files, so the dialog opens in `~/.ssh` and the user confirms), parses it with
/// `TildeServices.sshConfig`, shows a checkable preview and reports the choice. It never writes to the store.
///
/// - Hosts that match a saved server are flagged and start unchecked.
/// - `Host` patterns (`*`, `*.example.com`) are skipped.
/// - `ProxyJump` with a single hop is kept; chains are imported without a jump host and flagged.
/// - `IdentityFile` entries are listed, and the user can pick the key files so the app can import them.
public struct SSHConfigImportView: View {
    @Environment(\.tildeServices) private var services
    @Environment(\.dismiss) private var dismiss

    private let existingServers: [ServerSnapshot]
    private let previewText: String?
    private let onImportKeys: (([ImportedKeyFile]) -> Void)?
    private let onFinish: ([SSHConfigHost]) -> Void

    @State private var model: SSHConfigImportModel?
    @State private var importerPurpose: ImporterPurpose = .config
    @State private var showingImporter = false
    @State private var didAutoPresent = false

    private enum ImporterPurpose { case config, keys }

    /// Creates the import view.
    /// - Parameters:
    ///   - existingServers: saved servers, used to flag duplicates. Defaults to none.
    ///   - previewText: config text to load immediately instead of asking for a file (previews and tests).
    ///   - onImportKeys: called first, with the key files the user chose, so the app can run its key import
    ///     before the servers that reference them exist. Not called when no key file was chosen.
    ///   - onFinish: called once with the hosts to import; empty when the user cancels.
    public init(
        existingServers: [ServerSnapshot] = [],
        previewText: String? = nil,
        onImportKeys: (([ImportedKeyFile]) -> Void)? = nil,
        onFinish: @escaping ([SSHConfigHost]) -> Void = { _ in }
    ) {
        self.existingServers = existingServers
        self.previewText = previewText
        self.onImportKeys = onImportKeys
        self.onFinish = onFinish
    }

    public var body: some View {
        TildeSheet(
            "Import from ~/.ssh/config",
            subtitle: model?.sourceName.map { "Reading \($0)" } ?? "Choose your OpenSSH config file",
            idealHeight: 640
        ) {
            content
        } leading: {
            Button("Choose File…") { present(.config) }.buttonStyle(.tildeSheetSecondary)
        } actions: {
            TildeCancelButton {
                onFinish([])
                dismiss()
            }
            TildeDefaultButton(importTitle) { finish() }
                .disabled(!(model?.canImport ?? false))
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handlePicked
        )
        .startInSSHDirectory()
        .task { await prepare() }
    }

    // MARK: Pieces

    @ViewBuilder
    private var content: some View {
        if let model, !model.plan.rows.isEmpty {
            list(model)
        } else if let message = model?.errorMessage {
            ContentUnavailableView {
                Label("Nothing to import", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Choose Another File…") { present(.config) }.buttonStyle(.tildeSheetSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            ContentUnavailableView {
                Label("Import ~/.ssh/config", systemImage: "square.and.arrow.down")
            } description: {
                Text("Tilde runs in the App Sandbox, so it can only read files you pick. Choose your config file and review the servers before anything is saved.")
            } actions: {
                Button("Choose ~/.ssh/config…") { present(.config) }.buttonStyle(.tildeSheetPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private func list(_ model: SSHConfigImportModel) -> some View {
        VStack(alignment: .leading, spacing: TildeSpacing.l) {
            if let error = model.errorMessage {
                TildeNotice(error, tone: .danger)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(model.plan.rows.count) servers").tildeSectionHeader()
                    Spacer()
                    Button("All") { model.selectAll() }
                    Button("None") { model.selectNone() }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                TildeFormSection(
                    footer: model.plan.skippedPatterns.isEmpty ? nil
                        : "Skipped \(model.plan.skippedPatterns.count) wildcard \(model.plan.skippedPatterns.count == 1 ? "entry" : "entries"): \(model.plan.skippedPatterns.joined(separator: ", "))"
                ) {
                    ForEach(model.plan.rows) { row in
                        rowView(row, model: model)
                    }
                }
            }

            let jumpsMissing = model.unselectedJumpAliases
            if !jumpsMissing.isEmpty {
                TildeNotice("Selected servers jump through \(jumpsMissing.joined(separator: ", ")), which isn't checked. Check it too, or they will connect without the jump.",
                            tone: .warning, systemImage: "arrow.triangle.branch")
            }

            keysSection(model)
        }
    }

    private func rowView(_ row: SSHConfigImportRow, model: SSHConfigImportModel) -> some View {
        Toggle(isOn: Binding(
            get: { model.selection.contains(row.id) },
            set: { isOn in
                if isOn { model.selection.insert(row.id) } else { model.selection.remove(row.id) }
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: TildeSpacing.s) {
                    Text(row.host.alias).tildeMono(15, weight: .semibold).foregroundStyle(TildeColor.text)
                    if let conflict = row.conflict {
                        Text(conflictText(conflict))
                            .tildeText(12, relativeTo: .caption).foregroundStyle(TildeColor.warn)
                    }
                }
                Text(row.summary).tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(notes(for: row), id: \.self) { note in
                    Text(note).tildeText(12, relativeTo: .caption).foregroundStyle(TildeColor.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(CheckboxToggleStyle())
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func keysSection(_ model: SSHConfigImportModel) -> some View {
        let wanted = model.requestedIdentityFiles
        if !wanted.isEmpty {
            TildeFormSection(
                "Keys used by these servers",
                footer: "The config only names key files. Pick them here and Tilde will import them into your Keychain. Skip this to link keys later."
            ) {
                ForEach(wanted, id: \.self) { path in
                    let chosen = model.keyFiles.contains { $0.configPaths.contains(path) }
                    HStack {
                        Image(systemName: chosen ? "checkmark.circle.fill" : "key")
                            .foregroundStyle(chosen ? TildeColor.ok : TildeColor.text3)
                            .accessibilityHidden(true)
                        Text(path).tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                TildeActionRow("Choose Key Files…", systemImage: "folder") { present(.keys) }
            }
        }
    }

    // MARK: Behaviour

    private var importTitle: String {
        let count = model?.selection.count ?? 0
        return count == 1 ? "Import 1 Server" : "Import \(count) Servers"
    }

    private func conflictText(_ conflict: SSHConfigConflict) -> String {
        switch conflict {
        case .sameTarget(let name): "Already saved as \(name)"
        case .sameName(let name): "A server named \(name) exists"
        }
    }

    private func notes(for row: SSHConfigImportRow) -> [String] {
        var result: [String] = []
        switch row.jump {
        case .none: break
        case .single(let hop, let inConfig):
            result.append(inConfig ? "Jump host: \(hop)" : "Jump host: \(hop) (not defined in this file)")
        case .multiHop(let hops):
            result.append("ProxyJump \(hops.joined(separator: ", ")) has several hops. Tilde supports one, so this server imports without a jump host.")
        }
        let keys = row.host.identityFiles.filter { $0.lowercased() != "none" }
        if !keys.isEmpty { result.append("Key: \(keys.joined(separator: ", "))") }
        return result
    }

    private func present(_ purpose: ImporterPurpose) {
        importerPurpose = purpose
        showingImporter = true
    }

    private func prepare() async {
        if model == nil {
            model = SSHConfigImportModel(parser: services.sshConfig, existing: existingServers)
        }
        if let previewText, model?.plan.rows.isEmpty == true {
            model?.load(text: previewText, sourceName: "config")
        } else if previewText == nil, !didAutoPresent {
            didAutoPresent = true
            present(.config)
        }
    }

    private func handlePicked(_ result: Result<[URL], any Error>) {
        guard let model else { return }
        switch result {
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled { model.fail(error) }
        case .success(let urls):
            do {
                switch importerPurpose {
                case .config:
                    guard let url = urls.first else { return }
                    let file = try ImportFiles.read(url)
                    model.load(text: file.text, sourceName: file.name)
                case .keys:
                    let files = try urls.map { try ImportFiles.read($0) }
                    model.addKeyFiles(files.map { ($0.name, $0.data) })
                }
            } catch {
                model.fail(error)
            }
        }
    }

    private func finish() {
        guard let model else { return }
        if !model.keyFiles.isEmpty { onImportKeys?(model.keyFiles) }
        onFinish(model.selectedHosts)
        dismiss()
    }
}

#Preview("SSH config import") {
    SSHConfigImportView(
        existingServers: [PreviewServers.bastion],
        previewText: "preview"
    )
}
