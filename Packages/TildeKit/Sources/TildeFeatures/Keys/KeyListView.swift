import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeSecurity
import TildeStore

/// Key manager root (docs/DESIGN.md section 4.3): one row per key, with generate and import. Tapping a row opens
/// `KeyDetailView`. Place it inside a `NavigationStack`.
public struct KeyListView: View {
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case generate
        case importKey(pasted: String?)

        var id: String {
            switch self {
            case .generate: "generate"
            case .importKey: "import"
            }
        }
    }

    public init() {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.tildeIsUtilityWindow) private var isUtilityWindow

    public var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    private var iosBody: some View {
        Group {
            if keys.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(keys) { key in
                        NavigationLink {
                            KeyDetailView(key: key)
                        } label: {
                            KeyRow(key: key)
                        }
                        .listRowBackground(TildeColor.surface2)
                        .listRowSeparatorTint(TildeColor.border)
                    }
                }
                .tildeFormStyle()
            }
        }
        .background(TildeColor.bg)
        .navigationTitle("Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { addMenu }
        }
        .sheet(item: $sheet) { sheet in sheetContent(sheet).environment(\.tildeIsUtilityWindow, false) }
    }

    #if os(macOS)
    /// On the Mac the key manager is a sheet: the same scaffold as every other modal, with Add Key in the action bar.
    private var macBody: some View {
        TildeSheet("Keys", subtitle: keys.isEmpty ? nil : "\(keys.count) \(keys.count == 1 ? "key" : "keys")", scrolls: true, idealHeight: 520) {
            if keys.isEmpty {
                emptyState.frame(maxWidth: .infinity, minHeight: 280)
            } else {
                TildeFormSection {
                    ForEach(keys) { key in
                        NavigationLink {
                            KeyDetailView(key: key)
                        } label: {
                            HStack(spacing: TildeSpacing.s) {
                                KeyRow(key: key)
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(TildeColor.text3)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } leading: {
            addMenu.menuStyle(.button).buttonStyle(.tildeSheetSecondary).fixedSize()
        } actions: {
            if !isUtilityWindow { TildeDefaultButton("Done") { dismiss() } }
        }
        // The sheet is wrapped in a NavigationStack so a key can push its detail page; without this its empty system
        // title bar would sit above the sheet's own title row. Pushed screens bring their own bar and back button.
        .sheet(item: $sheet) { sheet in sheetContent(sheet).environment(\.tildeIsUtilityWindow, false) }
    }
    #endif

    private var addMenu: some View {
        Menu {
            Button("Generate Key…", systemImage: "wand.and.sparkles") { sheet = .generate }
            Button("Import Key…", systemImage: "square.and.arrow.down") { sheet = .importKey(pasted: nil) }
            Button("Paste Key from Clipboard…", systemImage: "doc.on.clipboard") {
                sheet = .importKey(pasted: SecureClipboard.currentString())
            }
        } label: {
            Label("Add Key", systemImage: "plus")
        }
        .accessibilityLabel("Add key")
    }

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case .generate:
            GenerateKeySheet()
        case .importKey(let pasted):
            ImportKeySheet(initialText: pasted ?? "")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No keys.", systemImage: "key")
        } description: {
            Text("Ed25519 takes 50 ms to generate.")
        } actions: {
            Button("Generate Ed25519 Key") { sheet = .generate }
                .buttonStyle(.borderedProminent)
                .tint(TildeColor.accentStrong)
            Button("Import Key…") { sheet = .importKey(pasted: nil) }
        }
    }
}

/// One row: key glyph, name, truncated fingerprint with server count, type badge, sync glyph.
struct KeyRow: View {
    let key: SSHKeyRecord

    var body: some View {
        HStack(spacing: TildeSpacing.m) {
            KeyGlyph()
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name)
                    .font(TildeFont.rowTitle)
                    .foregroundStyle(TildeColor.text)
                    .lineLimit(1)
                Text("\(key.shortFingerprint) · \(key.serverCountText)")
                    .font(TildeFont.rowSubtitle)
                    .foregroundStyle(TildeColor.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: TildeSpacing.s)
            TypeBadge(text: key.typeBadge)
            SyncGlyph(record: key)
        }
        .frame(minHeight: TildeSpacing.rowHeightMac)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key.name), \(key.typeSpokenName) key, used by \(key.serverCountText), \(key.isSynchronizable ? "synced with iCloud Keychain" : "this device only")")
        .accessibilityHint("Shows the public key and actions")
    }
}

#Preview("KeyListView") {
    NavigationStack { KeyListView() }
        .modelContainer(ModelContainerFactory.preview())
        .preferredColorScheme(.dark)
}

#Preview("KeyListView, empty") {
    NavigationStack { KeyListView() }
        .modelContainer(try! ModelContainerFactory.make(.inMemory))
        .preferredColorScheme(.dark)
}
