import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeSecurity
import TildeStore
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// Import flow (docs/DESIGN.md section 4.3): choose a file, paste, or drop a private key. Encrypted keys ask for their
/// passphrase; after import the key is stored decrypted in the Keychain and the passphrase is not kept.
///
/// Accepted: OpenSSH (`openssh-key-v1`), PEM PKCS#1 / SEC1 and PKCS#8 for Ed25519, ECDSA and RSA.
/// Rejected with a hint: PuTTY `.ppk`, DSA.
public struct ImportKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Query private var existingKeys: [SSHKeyRecord]

    private let onImported: ((SSHKeyRecord) -> Void)?

    @State private var text: String
    @State private var passphrase = ""
    @State private var needsPassphrase = false
    @State private var passphraseWasWrong = false
    @State private var parsed: Parsed?
    @State private var message: Message?
    @State private var name = ""
    @State private var comment = ""
    @State private var synchronizable = true
    @State private var isWorking = false
    @State private var showFileImporter = false
    @State private var suggestedName: String?
    @State private var parseTask: Task<Void, Never>?

    private struct Parsed {
        var info: PublicKeyInfo
        var material: PrivateKeyMaterial
    }

    private struct Message {
        var text: String
        var isError: Bool
    }

    /// - Parameters:
    ///   - initialText: pre-filled key text (the "Paste from Clipboard" shortcut).
    ///   - onImported: called with the new record once it is saved.
    public init(initialText: String = "", onImported: ((SSHKeyRecord) -> Void)? = nil) {
        self._text = State(initialValue: initialText)
        self.onImported = onImported
    }

    public var body: some View {
        NavigationStack {
            Form {
                keySection
                if needsPassphrase { passphraseSection }
                if let message {
                    Section {
                        Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .foregroundStyle(message.isError ? TildeColor.danger : TildeColor.text2)
                            .font(.system(size: 14))
                    }
                    .listRowBackground(TildeColor.surface2)
                }
                if let parsed { resultSection(parsed) }
            }
            .tildeFormStyle()
            .navigationTitle("Import Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importKey() }
                        .disabled(parsed == nil || trimmedName.isEmpty || duplicate != nil || isWorking)
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { load(url) }
            }
            .onChange(of: text) { _, _ in textChanged() }
            .onAppear { if !text.isEmpty { textChanged() } }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                load(url)
                return true
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .presentationDetents([.large])
    }

    // MARK: Sections

    private var keySection: some View {
        Section {
            TextEditor(text: $text)
                .font(TildeFont.mono(11))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .accessibilityLabel("Private key text")
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Paste a private key, or choose a file.\n-----BEGIN OPENSSH PRIVATE KEY-----")
                            .font(TildeFont.mono(11))
                            .foregroundStyle(TildeColor.text3)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            HStack {
                Button("Choose File…", systemImage: "folder") { showFileImporter = true }
                Spacer()
                Button("Paste", systemImage: "doc.on.clipboard") {
                    if let pasted = SecureClipboard.currentString() { text = pasted }
                }
                #if os(macOS)
                Button("~/.ssh…", systemImage: "terminal") { chooseFromSSHFolder() }
                #endif
            }
            .buttonStyle(.bordered)
            .tint(TildeColor.accent)
        } header: {
            Text("Private key").tildeSectionHeader()
        } footer: {
            Text("OpenSSH, PEM (PKCS#1, SEC1) and PKCS#8 keys: Ed25519, ECDSA, RSA.")
        }
        .listRowBackground(TildeColor.surface2)
    }

    private var passphraseSection: some View {
        Section {
            SecureField("Passphrase", text: $passphrase)
                .onSubmit { Task { await unlock() } }
                .accessibilityLabel("Key passphrase")
            Button(isWorking ? "Unlocking…" : "Unlock Key") { Task { await unlock() } }
                .disabled(passphrase.isEmpty || isWorking)
        } header: {
            Text("This key is encrypted").tildeSectionHeader()
        } footer: {
            Text(passphraseWasWrong ? "That passphrase is wrong." : "The passphrase is used once to decrypt the key and is not stored.")
                .foregroundStyle(passphraseWasWrong ? TildeColor.danger : TildeColor.text3)
        }
        .listRowBackground(TildeColor.surface2)
    }

    private func resultSection(_ parsed: Parsed) -> some View {
        Group {
            Section {
                HStack {
                    Text(parsed.info.algorithm.shortLabel(bits: parsed.info.bits))
                        .font(TildeFont.mono(13, weight: .semibold))
                    Spacer()
                    TypeBadge(text: parsed.info.algorithm.badge(bits: parsed.info.bits), tinted: true)
                }
                Text(parsed.info.fingerprintSHA256)
                    .font(TildeFont.mono(11))
                    .foregroundStyle(TildeColor.text2)
                    .textSelection(.enabled)
                    .accessibilityLabel("Fingerprint \(parsed.info.fingerprintSHA256)")
                if let duplicate {
                    Label("Already imported as “\(duplicate.name)”.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(TildeColor.warn)
                        .font(.system(size: 14))
                }
            } header: {
                Text("Key found").tildeSectionHeader()
            }
            .listRowBackground(TildeColor.surface2)

            Section {
                LabeledContent("Name") {
                    MonoField("Name", text: $name).multilineTextAlignment(.trailing)
                }
                LabeledContent("Comment") {
                    MonoField("Comment", text: $comment).multilineTextAlignment(.trailing)
                }
                Toggle("Sync via iCloud Keychain", isOn: $synchronizable)
            } footer: {
                Text("The key is stored unencrypted inside the Keychain, which protects it.")
            }
            .listRowBackground(TildeColor.surface2)
        }
    }

    // MARK: Logic

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var duplicate: SSHKeyRecord? {
        guard let parsed else { return nil }
        return existingKeys.first { $0.fingerprintSHA256 == parsed.info.fingerprintSHA256 }
    }

    private func textChanged() {
        parseTask?.cancel()
        parsed = nil
        message = nil
        needsPassphrase = false
        passphraseWasWrong = false
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        parseTask = Task { await attempt(passphrase: nil) }
    }

    private func unlock() async {
        guard !passphrase.isEmpty else { return }
        await attempt(passphrase: passphrase)
    }

    /// Parses off the main actor: decrypting runs bcrypt, which is deliberately slow.
    private func attempt(passphrase: String?) async {
        isWorking = true
        defer { isWorking = false }
        let data = Data(text.utf8)
        let service = services.keyService
        let result: Result<(PublicKeyInfo, PrivateKeyMaterial), KeyParseError> = await Task.detached(priority: .userInitiated) {
            do { return .success(try service.parse(privateKey: data, passphrase: passphrase)) } catch let error as KeyParseError { return .failure(error) } catch { return .failure(.unsupportedFormat("The key could not be read.")) }
        }.value
        if Task.isCancelled { return }
        switch result {
        case .success(let (info, material)):
            needsPassphrase = false
            passphraseWasWrong = false
            message = nil
            parsed = Parsed(info: info, material: material)
            if trimmedName.isEmpty { name = suggestedName ?? "\(DeviceInfo.slug)-\(info.algorithm.nameSuffix)-imported" }
            if comment.isEmpty { comment = info.comment }
        case .failure(.passphraseRequired):
            parsed = nil
            needsPassphrase = true
            message = nil
        case .failure(.wrongPassphrase):
            parsed = nil
            needsPassphrase = true
            passphraseWasWrong = true
        case .failure(.unsupportedFormat(let reason)), .failure(.unsupportedAlgorithm(let reason)):
            parsed = nil
            message = Message(text: reason, isError: true)
        }
    }

    private func importKey() {
        guard let parsed else { return }
        isWorking = true
        defer { isWorking = false }
        let info = parsed.info.replacingComment(comment.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            let record = try KeyStorage.save(
                info: info, material: parsed.material, name: trimmedName, source: "imported",
                synchronizable: synchronizable, services: services, context: context)
            onImported?(record)
            dismiss()
        } catch {
            message = Message(text: (error as? LocalizedError)?.errorDescription ?? "The key could not be imported.", isError: true)
        }
    }

    private func load(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= 64 * 1024 else {
                message = Message(text: "That file is too large to be a private key.", isError: true)
                return
            }
            let data = try Data(contentsOf: url)
            guard let string = String(data: data, encoding: .utf8) else {
                message = Message(text: "That file is not a text key file.", isError: true)
                return
            }
            suggestedName = url.deletingPathExtension().lastPathComponent
            name = ""
            comment = ""
            text = string
        } catch {
            message = Message(text: "The file could not be read.", isError: true)
        }
    }

    #if os(macOS)
    private func chooseFromSSHFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a private key from ~/.ssh"
        if let home = getpwuid(getuid()).flatMap({ String(validatingCString: $0.pointee.pw_dir) }) {
            panel.directoryURL = URL(fileURLWithPath: home).appendingPathComponent(".ssh", isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    #endif
}

extension SSHKeyAlgorithm {
    /// `Ed25519`, `ECDSA P-256`, `RSA 4096`.
    func shortLabel(bits: Int?) -> String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsaP256: "ECDSA P-256"
        case .ecdsaP384: "ECDSA P-384"
        case .ecdsaP521: "ECDSA P-521"
        case .rsa: "RSA \(bits ?? 0)"
        }
    }

    /// `ED25519`, `ECDSA-P256`, `RSA-4096`.
    func badge(bits: Int?) -> String {
        switch self {
        case .ed25519: "ED25519"
        case .ecdsaP256: "ECDSA-P256"
        case .ecdsaP384: "ECDSA-P384"
        case .ecdsaP521: "ECDSA-P521"
        case .rsa: "RSA-\(bits ?? 0)"
        }
    }

    var nameSuffix: String {
        switch self {
        case .ed25519: "ed25519"
        case .ecdsaP256: "ecdsa256"
        case .ecdsaP384: "ecdsa384"
        case .ecdsaP521: "ecdsa521"
        case .rsa: "rsa"
        }
    }
}

#Preview("ImportKeySheet") {
    ImportKeySheet()
        .modelContainer(ModelContainerFactory.preview())
        .preferredColorScheme(.dark)
}
