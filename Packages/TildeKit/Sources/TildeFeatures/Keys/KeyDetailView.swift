import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeSecurity
import TildeStore

/// A key's detail page (docs/DESIGN.md section 4.3): public key (tap to copy), fingerprint, randomart, share and copy
/// actions, "Install on server…", the used-by list, export (behind device authentication) and delete.
public struct KeyDetailView: View {
    let key: SSHKeyRecord

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Environment(\.tildeAuthenticator) private var authenticator

    @State private var sheet: Sheet?
    @State private var copied: CopiedItem?
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?
    @State private var isAuthenticating = false

    private enum Sheet: Identifiable {
        case install, export, reassignAndDelete
        var id: Self { self }
    }

    private enum CopiedItem { case publicKey, oneLiner }

    public init(key: SSHKeyRecord) {
        self.key = key
    }

    public var body: some View {
        Group {
            if key.isDeleted {
                Color.clear
            } else {
                content
            }
        }
        .background(TildeColor.bg)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TildeSpacing.l) {
                header
                if !KeyStorage.hasPrivateKey(key, services: services) { missingKeyBanner }
                publicKeyBlock
                fingerprintBlock
                actionGrid
                usedBySection
                footerActions
            }
            .padding(TildeSpacing.l)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(key.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rename", systemImage: "pencil") {
                    renameText = key.name
                    showRename = true
                }
            }
        }
        .alert("Rename Key", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete “\(key.name)”?", isPresented: $showDeleteConfirm) {
            Button("Delete Key", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The private key is removed from this device and from iCloud Keychain. This cannot be undone. Keep a copy if you still need it.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .install: InstallKeySheet(key: key)
            case .export: ExportPrivateKeySheet(key: key)
            case .reassignAndDelete: DeleteKeySheet(key: key) { dismiss() }
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: TildeSpacing.m) {
            KeyGlyph(highlighted: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                    .font(TildeFont.mono(15, weight: .semibold))
                    .foregroundStyle(TildeColor.text)
                Text(key.originSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(TildeColor.text2)
            }
            Spacer(minLength: TildeSpacing.s)
            TypeBadge(text: key.typeBadge, tinted: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key.name), \(key.typeSpokenName) key. \(key.originSubtitle)")
    }

    private var missingKeyBanner: some View {
        Banner(
            .warning,
            headline: key.isSynchronizable ? "Waiting for iCloud Keychain" : "Private key is not on this device",
            detail: key.isSynchronizable
                ? "The private key has not arrived from iCloud Keychain yet. You can still copy the public key."
                : "This key was created on \(key.originDeviceName.isEmpty ? "another device" : key.originDeviceName) and stays there.")
    }

    private var publicKeyBlock: some View {
        Button {
            SecureClipboard.copy(key.publicKeyOpenSSH)
            flash(.publicKey)
        } label: {
            publicKeyText
                .font(TildeFont.mono(11))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TildeSpacing.m)
                .background(TildeColor.bg, in: RoundedRectangle(cornerRadius: TildeRadius.card))
                .overlay(RoundedRectangle(cornerRadius: TildeRadius.card).stroke(TildeColor.border, lineWidth: TildeSpacing.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Public key")
        .accessibilityValue(key.publicKeyOpenSSH)
        .accessibilityHint("Copies the public key")
    }

    /// The mockup's `.pubkey`: accent algorithm, plain base64, dim comment.
    private var publicKeyText: Text {
        let parts = key.publicKeyOpenSSH.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return Text(key.publicKeyOpenSSH).foregroundStyle(TildeColor.text) }
        var algorithm = AttributedString(parts[0])
        algorithm.foregroundColor = TildeColor.accent
        var blob = AttributedString(" " + parts[1])
        blob.foregroundColor = TildeColor.text
        var result = algorithm + blob
        if parts.count > 2 {
            var comment = AttributedString(" " + parts[2])
            comment.foregroundColor = TildeColor.text3
            result += comment
        }
        return Text(result)
    }

    private var fingerprintBlock: some View {
        VStack(alignment: .leading, spacing: TildeSpacing.s) {
            Text(key.fingerprintSHA256)
                .font(TildeFont.mono(11, weight: .medium))
                .foregroundStyle(TildeColor.text3)
                .textSelection(.enabled)
                .accessibilityLabel("Fingerprint \(key.fingerprintSHA256)")
            if let art = RandomArt.render(fingerprintSHA256: key.fingerprintSHA256, algorithm: key.algorithm ?? .ed25519, bits: key.bits) {
                DisclosureGroup("Randomart") {
                    Text(art)
                        .font(TildeFont.mono(12))
                        .foregroundStyle(TildeColor.text2)
                        .fixedSize()
                        .padding(.top, TildeSpacing.xs)
                        .accessibilityLabel("Randomart picture of the fingerprint")
                }
                .font(.system(size: 13))
                .foregroundStyle(TildeColor.text2)
            }
        }
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: TildeSpacing.s) {
            Button {
                SecureClipboard.copy(key.publicKeyOpenSSH)
                flash(.publicKey)
            } label: {
                Label(copied == .publicKey ? "Copied" : "Copy public key", systemImage: copied == .publicKey ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(KeyActionButtonStyle(isPrimary: true))

            Menu {
                ShareLink(item: key.publicKeyOpenSSH) { Label("Share as Text", systemImage: "text.alignleft") }
                ShareLink(item: PublicKeyFile(fileName: "\(key.name).pub", line: key.publicKeyOpenSSH),
                          preview: SharePreview("\(key.name).pub")) {
                    Label("Share as .pub File", systemImage: "doc")
                }
            } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.button)
            .buttonStyle(KeyActionButtonStyle())

            Button { sheet = .install } label: {
                Label("Install on server…", systemImage: "server.rack")
            }
            .buttonStyle(KeyActionButtonStyle())

            Button {
                SecureClipboard.copy(AuthorizedKeysCommand.oneLiner(publicKeyLine: key.publicKeyOpenSSH))
                flash(.oneLiner)
            } label: {
                Label(copied == .oneLiner ? "Copied" : "Copy one-liner", systemImage: copied == .oneLiner ? "checkmark" : "terminal")
            }
            .buttonStyle(KeyActionButtonStyle())
            .accessibilityHint("Copies a shell command that adds this key to authorized_keys")
        }
    }

    private var usedBySection: some View {
        VStack(alignment: .leading, spacing: TildeSpacing.xs) {
            Text("Used by").tildeSectionHeader()
            let servers = (key.servers ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if servers.isEmpty {
                Text("No servers use this key yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(TildeColor.text3)
            } else {
                ForEach(servers) { server in
                    HStack {
                        Text(server.name.isEmpty ? server.host : server.name)
                            .font(TildeFont.mono(13))
                            .foregroundStyle(TildeColor.text)
                        Spacer()
                        EnvBadge(EnvTone(rawValue: server.environmentRaw) ?? .none)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var footerActions: some View {
        HStack {
            Button("Export private key…") { beginExport() }
                .foregroundStyle(TildeColor.text2)
                .disabled(isAuthenticating || !KeyStorage.hasPrivateKey(key, services: services))
            Spacer()
            Button("Delete", role: .destructive) {
                if key.serverCount > 0 { sheet = .reassignAndDelete } else { showDeleteConfirm = true }
            }
            .foregroundStyle(TildeColor.danger)
        }
        .font(.system(size: 13, weight: .semibold))
        .buttonStyle(.plain)
        .padding(.top, TildeSpacing.xs)
    }

    // MARK: Actions

    private func flash(_ item: CopiedItem) {
        copied = item
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == item { copied = nil }
        }
    }

    private func rename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        key.name = trimmed
        key.updatedAt = .now
        try? context.save()
    }

    /// Export needs the device owner (Face ID / Touch ID / passcode) before the sheet opens.
    private func beginExport() {
        guard !isAuthenticating else { return }
        guard authenticator.canAuthenticate else {
            sheet = .export  // a device with no lock at all: nothing to ask for
            return
        }
        isAuthenticating = true
        Task {
            let ok = await authenticator.authenticate(reason: "Export the private key “\(key.name)”.")
            isAuthenticating = false
            if ok { sheet = .export }
        }
    }

    private func delete() {
        do {
            try KeyStorage.delete(key, services: services, context: context)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "The key could not be deleted."
        }
    }
}

/// The mockup's `.act` button: 40 pt, rounded 11, surface fill with a hairline border; primary is solid accent.
struct KeyActionButtonStyle: ButtonStyle {
    var isPrimary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(isPrimary ? Color(hex: 0x04201C) : TildeColor.text)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(isPrimary ? TildeColor.accent : TildeColor.surface2, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(isPrimary ? TildeColor.accent : TildeColor.border, lineWidth: TildeSpacing.hairline))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

#Preview("KeyDetailView") {
    NavigationStack {
        KeyDetailPreviewHost()
    }
    .modelContainer(ModelContainerFactory.preview())
    .environment(\.tildeAuthenticator, StubAuthenticator())
    .preferredColorScheme(.dark)
}

private struct KeyDetailPreviewHost: View {
    @Query private var keys: [SSHKeyRecord]

    var body: some View {
        if let key = keys.first { KeyDetailView(key: key) } else { Text("No preview key") }
    }
}
