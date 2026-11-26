import SwiftUI
import TildeCore
import TildeDesign

/// Imports pinned host keys from an OpenSSH `known_hosts` file.
///
/// The user picks the file (the App Sandbox does not allow reading `~/.ssh` on its own), reviews the keys, and
/// the checked ones are pinned through `TildeServices.knownHosts` (`KnownHostsStore.trust`). Pins that already
/// exist are left alone: a host whose pinned key differs from the file is listed as a conflict and is never
/// overwritten. Hashed entries (`|1|...`) can't be read and are counted, not imported.
public struct KnownHostsImportView: View {
    @Environment(\.tildeServices) private var services
    @Environment(\.dismiss) private var dismiss

    private let previewText: String?
    private let onFinish: (KnownHostsImportSummary?) -> Void

    @State private var model = KnownHostsImportModel()
    @State private var showingImporter = false
    @State private var didAutoPresent = false

    /// Creates the import view.
    /// - Parameters:
    ///   - previewText: `known_hosts` text to load immediately instead of asking for a file (previews and tests).
    ///   - onFinish: called when the sheet closes, with the outcome, or `nil` if the user cancelled.
    public init(previewText: String? = nil, onFinish: @escaping (KnownHostsImportSummary?) -> Void = { _ in }) {
        self.previewText = previewText
        self.onFinish = onFinish
    }

    public var body: some View {
        TildeSheet(
            "Import known_hosts",
            subtitle: model.sourceName.map { "Reading \($0)" } ?? "Choose your OpenSSH known_hosts file",
            idealHeight: 600
        ) {
            content
        } leading: {
            Button("Choose File…") { showingImporter = true }
                .buttonStyle(.tildeSheetSecondary)
                .disabled(model.isWorking)
        } actions: {
            if let summary = model.summary {
                TildeDefaultButton("Done") {
                    onFinish(summary)
                    dismiss()
                }
            } else {
                TildeCancelButton {
                    onFinish(nil)
                    dismiss()
                }
                TildeDefaultButton(importTitle) {
                    Task { await model.importSelected(using: services.knownHosts) }
                }
                .disabled(model.selection.isEmpty || model.isWorking)
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: false, onCompletion: handlePicked)
        .startInSSHDirectory()
        .task { await prepare() }
    }

    // MARK: Pieces

    @ViewBuilder
    private var content: some View {
        if let summary = model.summary {
            resultView(summary)
        } else if !model.result.entries.isEmpty {
            list
        } else if let message = model.errorMessage {
            ContentUnavailableView {
                Label("Nothing to import", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Choose Another File…") { showingImporter = true }.buttonStyle(.tildeSheetSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            ContentUnavailableView {
                Label("Import known_hosts", systemImage: "lock.shield")
            } description: {
                Text("Pin the host keys you already trust, so Tilde warns you if any of those servers ever presents a different key. Choose your known_hosts file and review the entries first.")
            } actions: {
                Button("Choose ~/.ssh/known_hosts…") { showingImporter = true }.buttonStyle(.tildeSheetPrimary)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: TildeSpacing.l) {
            let fresh = model.entries(.new)
            if !fresh.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(fresh.count) new").tildeSectionHeader()
                        Spacer()
                        Button("All") { model.selection.formUnion(fresh.map(\.id)) }
                        Button("None") { model.selection.subtract(fresh.map(\.id)) }
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 4)
                    TildeFormSection {
                        ForEach(fresh) { entry in checkRow(entry) }
                    }
                }
            }

            let conflicts = model.entries(.conflict)
            if !conflicts.isEmpty {
                TildeFormSection("\(conflicts.count) conflicts") {
                    ForEach(conflicts) { entry in
                        entryLabel(entry, note: model.ambiguousIDs.contains(entry.id)
                            ? "This file lists more than one key of this type for the host. Not imported."
                            : "A different key is pinned for this host. Not imported. Connect to the host to review the change.")
                            .foregroundStyle(TildeColor.warn)
                            .padding(.vertical, 6)
                    }
                }
            }

            let trusted = model.entries(.alreadyTrusted)
            if !trusted.isEmpty {
                TildeNotice("\(trusted.count) already pinned with the same key", tone: .info, systemImage: "checkmark.seal")
            }

            if model.result.hashedCount > 0 {
                TildeNotice("\(model.result.hashedCount) hashed entries skipped. Hashed host names can't be turned back into hosts.",
                            tone: .info, systemImage: "number")
            }

            let others = model.result.otherSkips
            if !others.isEmpty {
                TildeNotice("\(others.count) other lines skipped (wildcards, certificate authorities, unsupported key types).",
                            tone: .info, systemImage: "minus.circle")
            }
        }
    }

    private func checkRow(_ entry: KnownHostsEntry) -> some View {
        Toggle(isOn: Binding(
            get: { model.selection.contains(entry.id) },
            set: { isOn in
                if isOn { model.selection.insert(entry.id) } else { model.selection.remove(entry.id) }
            }
        )) {
            entryLabel(entry, note: nil)
        }
        .toggleStyle(CheckboxToggleStyle())
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func entryLabel(_ entry: KnownHostsEntry, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.endpoint.port == 22 ? entry.endpoint.host : "\(entry.endpoint.host):\(entry.endpoint.port)")
                .tildeMono(15, weight: .semibold).foregroundStyle(TildeColor.text)
            Text("\(algorithmLabel(entry.key.algorithm))  \(entry.key.fingerprintSHA256)")
                .tildeMono(11).foregroundStyle(TildeColor.text2)
                .lineLimit(1).truncationMode(.middle)
            if let note { Text(note).tildeText(12, relativeTo: .caption).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultView(_ summary: KnownHostsImportSummary) -> some View {
        ContentUnavailableView {
            Label(summary.imported == 1 ? "Pinned 1 host key" : "Pinned \(summary.imported) host keys", systemImage: "checkmark.seal.fill")
        } description: {
            VStack(spacing: 4) {
                if summary.alreadyTrusted > 0 { Text("\(summary.alreadyTrusted) were already pinned.") }
                if summary.conflicts > 0 { Text("\(summary.conflicts) conflicted with an existing pin and were left alone.") }
                if summary.failed > 0 { Text("\(summary.failed) could not be saved.").foregroundStyle(TildeColor.danger) }
                if summary.hashedSkipped > 0 { Text("\(summary.hashedSkipped) hashed entries could not be read.") }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: Behaviour

    private var importTitle: String {
        model.selection.count == 1 ? "Pin 1 Host Key" : "Pin \(model.selection.count) Host Keys"
    }

    private func algorithmLabel(_ algorithm: String) -> String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case "ecdsa-sha2-nistp256": "ECDSA-256"
        case "ecdsa-sha2-nistp384": "ECDSA-384"
        case "ecdsa-sha2-nistp521": "ECDSA-521"
        default: algorithm
        }
    }

    private func prepare() async {
        if let previewText, model.result.entries.isEmpty {
            model.load(text: previewText, sourceName: "known_hosts")
            await model.classify(using: services.knownHosts)
        } else if previewText == nil, !didAutoPresent {
            didAutoPresent = true
            showingImporter = true
        }
    }

    private func handlePicked(_ result: Result<[URL], any Error>) {
        switch result {
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled { model.fail(error) }
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let file = try ImportFiles.read(url)
                model.load(text: file.text, sourceName: file.name)
                Task { await model.classify(using: services.knownHosts) }
            } catch {
                model.fail(error)
            }
        }
    }
}

#Preview("known_hosts import") {
    KnownHostsImportView(previewText: """
        db-primary.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
        [10.0.2.5]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
        |1|F1E1KeoE/eEWhi10WpGv4OdiO6Y=|3988QV0VbkuUlFskmfOfUZhJKxE= ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
        """)
}
