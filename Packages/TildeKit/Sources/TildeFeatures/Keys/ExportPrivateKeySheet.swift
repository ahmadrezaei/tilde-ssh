import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeSecurity
import TildeStore
import UniformTypeIdentifiers

/// "Export private key" (docs/DESIGN.md section 4.3). Presented only after device authentication. Exports OpenSSH
/// format, optionally protected by a passphrase, as a copy (the clipboard clears itself), a share, or a file.
struct ExportPrivateKeySheet: View {
    let key: SSHKeyRecord

    @Environment(\.dismiss) private var dismiss
    @Environment(\.tildeServices) private var services
    @Environment(\.tildeAppLock) private var appLock
    @Environment(\.scenePhase) private var scenePhase

    @State private var protectWithPassphrase = true
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var exported: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showFileExporter = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text("Anyone who has this file can sign in to your servers as you. Share it only with yourself, and prefer a passphrase.")
                            .font(.system(size: 14))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TildeColor.danger)
                    }
                }
                .listRowBackground(TildeColor.danger.opacity(0.12))

                if exported == nil {
                    Section {
                        Toggle("Protect with a passphrase", isOn: $protectWithPassphrase)
                        if protectWithPassphrase {
                            SecureField("Passphrase (5+ characters)", text: $passphrase)
                            SecureField("Repeat passphrase", text: $confirmation)
                        }
                    } footer: {
                        Text(protectWithPassphrase
                            ? "The exported file is encrypted with aes256-ctr and bcrypt-pbkdf, like ssh-keygen does."
                            : "The exported file will be readable by anyone who gets it.")
                    }
                    .listRowBackground(TildeColor.surface2)

                    Section {
                        Button(isWorking ? "Preparing…" : "Prepare Export") { Task { await prepare() } }
                            .disabled(!canPrepare || isWorking)
                    }
                    .listRowBackground(TildeColor.surface2)
                } else if let exported {
                    Section {
                        Button(copied ? "Copied" : "Copy Private Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            SecureClipboard.copySecret(exported)
                            copied = true
                        }
                        ShareLink(item: exported, subject: Text("Private key \(key.name)")) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        Button("Save to File…", systemImage: "folder") { showFileExporter = true }
                    } footer: {
                        Text(clipboardFooter)
                    }
                    .listRowBackground(TildeColor.surface2)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(TildeColor.danger)
                            .font(.system(size: 14))
                    }
                    .listRowBackground(TildeColor.surface2)
                }
            }
            .tildeFormStyle()
            .navigationTitle("Export Key")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileExporter(
                isPresented: $showFileExporter,
                document: KeyFileDocument(data: Data((exported ?? "").utf8)),
                contentType: .data,
                defaultFilename: fileName
            ) { _ in }
            .onDisappear(perform: wipe)
            // The lock screen lives in its own window above this sheet, but the exported key must not outlive the
            // lock: drop it and close the sheet the moment the app locks or leaves the foreground.
            .onChange(of: appLock?.isLocked ?? false) { _, locked in
                if locked { closeAndWipe() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { closeAndWipe() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
        .presentationDetents([.medium, .large])
    }

    private func wipe() {
        exported = nil
        passphrase = ""
        confirmation = ""
        showFileExporter = false
    }

    private func closeAndWipe() {
        wipe()
        dismiss()
    }

    private var canPrepare: Bool {
        !protectWithPassphrase || (passphrase.count >= 5 && passphrase == confirmation)
    }

    private var clipboardFooter: String {
        let seconds = SecuritySettings.shared.clipboardClearSeconds
        return seconds > 0
            ? "A copied key is removed from the clipboard after \(seconds) seconds and stays off Universal Clipboard."
            : "Clipboard clearing is off (Settings > Security)."
    }

    private var fileName: String {
        let safe = key.name.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return safe.isEmpty ? "tilde_key" : safe
    }

    private func prepare() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        let store = services.secretStore
        let ref = key.secretRef
        let passphrase = protectWithPassphrase ? passphrase : nil
        let result: Result<String, Error> = await Task.detached(priority: .userInitiated) {
            do {
                guard let stored = try store.read(ref) else { throw ExportError.notOnDevice }
                let data = try OpenSSHPrivateKeyCodec.export(openSSHBytes: stored, passphrase: passphrase)
                return .success(String(decoding: data, as: UTF8.self))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let text): exported = text
        case .failure(let error):
            errorMessage = (error as? ExportError)?.message ?? "The key could not be exported."
        }
    }

    private enum ExportError: Error {
        case notOnDevice
        var message: String { "The private key is not on this device." }
    }
}

#Preview("ExportPrivateKeySheet") {
    ExportKeyPreviewHost()
        .modelContainer(ModelContainerFactory.preview())
        .preferredColorScheme(.dark)
}

private struct ExportKeyPreviewHost: View {
    @Query private var keys: [SSHKeyRecord]

    var body: some View {
        if let key = keys.first { ExportPrivateKeySheet(key: key) } else { Text("No preview key") }
    }
}
