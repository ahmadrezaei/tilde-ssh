import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// Picker used by the server editor's Authentication section (docs/DESIGN.md section 4.2): the keys with type and
/// fingerprint tail, plus "Generate new Ed25519…" inline. Embed it in a `Form` section.
public struct KeyPicker: View {
    @Binding private var selection: SSHKeyRecord?
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    @State private var showGenerate = false

    public init(selection: Binding<SSHKeyRecord?>) {
        self._selection = selection
    }

    public var body: some View {
        Group {
            Picker("Key", selection: $selection) {
                Text("None").tag(SSHKeyRecord?.none)
                ForEach(keys) { key in
                    Text(label(for: key)).tag(Optional(key))
                }
            }
            Button("Generate new Ed25519…", systemImage: "wand.and.sparkles") { showGenerate = true }
        }
        .sheet(isPresented: $showGenerate) {
            GenerateKeySheet { created in selection = created }
        }
    }

    /// `iphone-ed25519 · ED25519 · …Vw0`
    private func label(for key: SSHKeyRecord) -> String {
        let tail = key.fingerprintSHA256.suffix(3)
        return "\(key.name) · \(key.typeBadge) · …\(tail)"
    }
}

#Preview("KeyPicker") {
    @Previewable @State var selection: SSHKeyRecord?
    Form { KeyPicker(selection: $selection) }
        .modelContainer(ModelContainerFactory.preview())
        .preferredColorScheme(.dark)
}
