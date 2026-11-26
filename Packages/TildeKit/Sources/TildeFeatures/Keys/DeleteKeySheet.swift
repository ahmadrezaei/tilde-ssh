import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeSecurity
import TildeStore

/// Delete is blocked while servers use the key, unless you reassign them (docs/DESIGN.md section 4.3). This sheet lists
/// those servers and moves them to another key, or to "ask for a password every time", before deleting.
struct DeleteKeySheet: View {
    let key: SSHKeyRecord
    let onDeleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Query(sort: \SSHKeyRecord.name) private var allKeys: [SSHKeyRecord]

    /// `nil` = "ask for a password every time".
    @State private var replacementID: UUID?
    @State private var errorMessage: String?

    private var otherKeys: [SSHKeyRecord] { allKeys.filter { $0.id != key.id } }
    private var affected: [Server] { (key.servers ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    var body: some View {
        TildeSheet("Delete Key", subtitle: key.name, subtitleIsMono: true, idealHeight: 520) {
            VStack(alignment: .leading, spacing: TildeSpacing.l) {
                TildeFormSection("\(affected.count == 1 ? "1 server uses" : "\(affected.count) servers use") this key") {
                    ForEach(affected) { server in
                        HStack {
                            Text(server.name.isEmpty ? server.host : server.name).tildeMono(13)
                                .foregroundStyle(TildeColor.text)
                            Spacer()
                            EnvBadge(EnvTone(rawValue: server.environmentRaw) ?? .none)
                        }
                    }
                }

                TildeFormSection(footer: "These servers are changed first, then “\(key.name)” is deleted from this device and iCloud Keychain. This cannot be undone.") {
                    TildePickerRow("Switch them to", selection: $replacementID) {
                        Text("Ask for a password").tag(UUID?.none)
                        ForEach(otherKeys) { other in
                            Text("\(other.name) · \(other.typeBadge)").tag(Optional(other.id))
                        }
                    }
                }

                if let errorMessage {
                    TildeNotice(errorMessage, tone: .danger)
                }
            }
        } actions: {
            TildeCancelButton { dismiss() }
            Button("Reassign and Delete") { reassignAndDelete() }
                .buttonStyle(.tildeSheetDestructive)
        }
        .presentationDetents([.medium, .large])
    }

    private func reassignAndDelete() {
        let replacement = otherKeys.first { $0.id == replacementID }
        for server in affected {
            server.key = replacement
            server.authMethodRaw = (replacement == nil ? AuthMethod.passwordPrompt : AuthMethod.key).rawValue
            server.updatedAt = .now
        }
        do {
            try KeyStorage.delete(key, services: services, context: context)
            dismiss()
            onDeleted()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "The key could not be deleted."
        }
    }
}
