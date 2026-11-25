import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeSecurity
import TildeStore

/// "Generate key" sheet (docs/DESIGN.md section 4.3): name, type (Ed25519 by default), comment and the iCloud
/// Keychain toggle. Creates the Keychain item and the `SSHKeyRecord`.
public struct GenerateKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services

    private let onCreated: ((SSHKeyRecord) -> Void)?

    @State private var name = ""
    @State private var comment = ""
    @State private var choice: KeyTypeChoice = .ed25519
    @State private var synchronizable = true
    @State private var isGenerating = false
    @State private var errorMessage: String?
    /// The last defaults we filled in; a field counts as user-edited once it differs from them.
    @State private var autoName = ""
    @State private var autoComment = ""

    /// - Parameter onCreated: called with the new record after it is saved (the server editor uses it to select the key).
    public init(onCreated: ((SSHKeyRecord) -> Void)? = nil) {
        self.onCreated = onCreated
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        MonoField("iphone-ed25519", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Type", selection: $choice) {
                        ForEach(KeyTypeChoice.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Comment") {
                        MonoField("tilde@iphone", text: $comment)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text(choice.detail)
                }
                .listRowBackground(TildeColor.surface2)

                Section {
                    Toggle("Sync via iCloud Keychain", isOn: $synchronizable)
                } footer: {
                    Text(synchronizable
                        ? "The private key is stored in iCloud Keychain, end-to-end encrypted, and appears on your other devices."
                        : "The private key stays on this device and is not backed up to iCloud.")
                }
                .listRowBackground(TildeColor.surface2)

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
            .navigationTitle("New Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isGenerating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isGenerating {
                        ProgressView().accessibilityLabel("Generating key")
                    } else {
                        Button("Generate") { Task { await generate() } }
                            .disabled(trimmedName.isEmpty)
                    }
                }
            }
            .onAppear(perform: applyDefaults)
            .onChange(of: choice) { _, _ in applyDefaults() }
            .interactiveDismissDisabled(isGenerating)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
        .presentationDetents([.medium, .large])
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Fills the defaults (`iphone-ed25519`, `tilde@iphone`) until the user types their own.
    private func applyDefaults() {
        if name == autoName {
            autoName = "\(DeviceInfo.slug)-\(choice.nameSuffix)"
            name = autoName
        }
        if comment == autoComment {
            autoComment = "tilde@\(DeviceInfo.slug)"
            comment = autoComment
        }
    }

    private func generate() async {
        errorMessage = nil
        isGenerating = true
        defer { isGenerating = false }
        do {
            let (info, material) = try await services.keyService.generate(choice.algorithm, bits: choice.bits, comment: comment.trimmingCharacters(in: .whitespacesAndNewlines))
            let record = try KeyStorage.save(
                info: info, material: material, name: trimmedName, source: "generated",
                synchronizable: synchronizable, services: services, context: context)
            onCreated?(record)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "The key could not be generated."
        }
    }
}

/// The key types offered when generating.
enum KeyTypeChoice: String, CaseIterable, Identifiable {
    case ed25519, ecdsaP256, ecdsaP384, ecdsaP521, rsa3072, rsa4096

    var id: String { rawValue }

    var algorithm: SSHKeyAlgorithm {
        switch self {
        case .ed25519: .ed25519
        case .ecdsaP256: .ecdsaP256
        case .ecdsaP384: .ecdsaP384
        case .ecdsaP521: .ecdsaP521
        case .rsa3072, .rsa4096: .rsa
        }
    }

    var bits: Int? {
        switch self {
        case .rsa3072: 3072
        case .rsa4096: 4096
        default: nil
        }
    }

    var title: String {
        switch self {
        case .ed25519: "Ed25519 (recommended)"
        case .ecdsaP256: "ECDSA P-256"
        case .ecdsaP384: "ECDSA P-384"
        case .ecdsaP521: "ECDSA P-521"
        case .rsa3072: "RSA 3072 (compatibility)"
        case .rsa4096: "RSA 4096 (compatibility)"
        }
    }

    var nameSuffix: String {
        switch self {
        case .ed25519: "ed25519"
        case .ecdsaP256: "ecdsa256"
        case .ecdsaP384: "ecdsa384"
        case .ecdsaP521: "ecdsa521"
        case .rsa3072: "rsa3072"
        case .rsa4096: "rsa4096"
        }
    }

    var detail: String {
        switch self {
        case .ed25519: "Small, fast and supported by every modern OpenSSH server."
        case .ecdsaP256, .ecdsaP384, .ecdsaP521: "Widely supported elliptic-curve key."
        case .rsa3072, .rsa4096: "For old servers and appliances that cannot use Ed25519. Takes about a second to generate."
        }
    }
}

#Preview("GenerateKeySheet") {
    GenerateKeySheet()
        .modelContainer(ModelContainerFactory.preview())
        .preferredColorScheme(.dark)
}
