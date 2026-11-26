import SwiftUI
import TildeDesign
import UniformTypeIdentifiers

/// Settings > Keyboard > Key bar: a live preview, presets, pages (reorder, add, delete, 1 to 8) with six slots each, a key
/// catalog for every slot, flick alternates, and import/export of the layout as JSON (`.tildekeys`).
///
/// `KeyBarEditorView()` edits the layout stored in `TerminalSettings.shared`; pass `settings` to edit another store.
public struct KeyBarEditorView: View {
    @Bindable private var settings: TerminalSettings

    public init(settings: TerminalSettings = .shared) {
        self.settings = settings
    }

    public var body: some View {
        KeyBarLayoutEditor(layout: $settings.keyBarLayout)
    }
}

/// The editor over any `KeyBarLayout` binding (used by `KeyBarEditorView` and by previews).
public struct KeyBarLayoutEditor: View {
    @Binding var layout: KeyBarLayout
    @State private var previewPage = 0
    @State private var editing: SlotAddress?
    @State private var importing = false
    @State private var importError: String?
    @State private var confirmReset = false

    public init(layout: Binding<KeyBarLayout>) {
        _layout = layout
    }

    struct SlotAddress: Identifiable, Equatable {
        var page: UUID
        var slot: UUID
        var id: UUID { slot }
    }

    public var body: some View {
        List {
            Section {
                KeyBarPreview(layout: layout, page: min(previewPage, layout.pages.count - 1))
                    .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8))
                    .listRowBackground(TildeColor.surface)
                if layout.pages.count > 1 {
                    Picker("Preview page", selection: $previewPage) {
                        ForEach(Array(layout.pages.enumerated()), id: \.element.id) { index, page in
                            Text(page.name).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            } header: { Text("Preview").tildeSectionHeader() }

            Section {
                Menu {
                    ForEach(KeyBarLayout.presets, id: \.presetName) { preset in
                        Button(preset.presetName) { apply(preset) }
                    }
                } label: {
                    HStack {
                        Text("Preset")
                        Spacer()
                        Text(layout.presetName).foregroundStyle(TildeColor.text2)
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(TildeColor.text3)
                    }
                }
                Toggle("Show Alt key", isOn: $layout.showsAlt)
                Picker("tmux prefix", selection: $layout.tmuxPrefix) {
                    ForEach(Array("abcdefghijklmnopqrstuvwxyz"), id: \.self) { letter in
                        Text("^\(String(letter).uppercased())").tag(String(letter))
                    }
                }
                Text("Esc and Ctrl are always pinned on the left. Flick a key up to send its small alternate.")
                    .font(.footnote).foregroundStyle(TildeColor.text3)
            } header: { Text("Layout").tildeSectionHeader() }

            ForEach($layout.pages) { $page in
                Section {
                    TextField("Page name", text: $page.name)
                    ForEach($page.slots) { $slot in
                        Button {
                            editing = SlotAddress(page: page.id, slot: slot.id)
                        } label: {
                            SlotRow(slot: slot)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text(page.name).tildeSectionHeader()
                        Spacer()
                        if layout.pages.count > 1 {
                            Button(role: .destructive) { deletePage(page.id) } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Delete page \(page.name)")
                        }
                    }
                }
            }
            .onMove { layout.pages.move(fromOffsets: $0, toOffset: $1) }

            Section {
                Button {
                    layout.pages.append(KeyBarPage(name: "Page \(layout.pages.count + 1)", slots: []))
                } label: { Label("Add page", systemImage: "plus") }
                    .disabled(layout.pages.count >= KeyBarLayout.maxPages)
                ShareLink(item: exportText, subject: Text("Tilde key bar"), preview: SharePreview("Tilde key bar layout.tildekeys")) {
                    Label("Export layout", systemImage: "square.and.arrow.up")
                }
                Button { importing = true } label: { Label("Import layout", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { confirmReset = true } label: { Label("Reset to DevOps", systemImage: "arrow.counterclockwise") }
            } footer: {
                if let importError { Text(importError).foregroundStyle(TildeColor.danger) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(TildeColor.bg)
        .navigationTitle("Key bar")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        #endif
        .sheet(item: $editing) { address in
            if let binding = slotBinding(address) {
                SlotEditor(slot: binding, tmuxPrefix: layout.tmuxPrefix)
                    .presentationDetents([.large])
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
            importLayout(result)
        }
        .confirmationDialog("Replace your key bar with the DevOps preset?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { apply(.devOps) }
        }
    }

    // MARK: Actions

    private func apply(_ preset: KeyBarLayout) {
        var copy = preset
        copy.tmuxPrefix = layout.tmuxPrefix
        copy.showsAlt = layout.showsAlt
        layout = copy
        previewPage = 0
    }

    private func deletePage(_ id: UUID) {
        guard layout.pages.count > 1 else { return }
        layout.pages.removeAll { $0.id == id }
        previewPage = 0
    }

    private func slotBinding(_ address: SlotAddress) -> Binding<KeySlot>? {
        guard let p = layout.pages.firstIndex(where: { $0.id == address.page }),
              let s = layout.pages[p].slots.firstIndex(where: { $0.id == address.slot }) else { return nil }
        return Binding(get: { layout.pages[p].slots[s] }, set: { layout.pages[p].slots[s] = $0 })
    }

    private var exportText: String {
        (try? layout.jsonData()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func importLayout(_ result: Result<URL, Error>) {
        importError = nil
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var imported = try KeyBarLayout.decode(from: Data(contentsOf: url))
            imported.presetName = "Imported"
            layout = imported
            previewPage = 0
        } catch KeyBarLayoutError.unsupportedVersion(let version) {
            importError = "This layout was made by a newer version of Tilde (format \(version))."
        } catch {
            importError = "That file is not a Tilde key bar layout."
        }
    }
}

// MARK: - Preview rendition of the bar

/// A non-interactive drawing of the key bar for one page, using the same geometry ratios as the real one.
struct KeyBarPreview: View {
    let layout: KeyBarLayout
    let page: Int

    var body: some View {
        let pinned: [KeyAction] = layout.showsAlt ? [.key(.escape), .modifier(.ctrl), .modifier(.alt)] : [.key(.escape), .modifier(.ctrl)]
        VStack(spacing: 4) {
            HStack(spacing: 3) {
                ForEach(Array(pinned.enumerated()), id: \.offset) { _, action in
                    PreviewKey(label: action.defaultLabel, alternate: nil)
                }
                Color.clear.frame(width: 3)
                if layout.pages.indices.contains(page) {
                    ForEach(layout.pages[page].slots) { slot in
                        PreviewKey(label: slot.displayLabel, alternate: slot.displayAlternateLabel)
                    }
                }
                Color.clear.frame(width: 3)
                PreviewKey(label: "✣", alternate: nil)
            }
            HStack(spacing: 6) {
                ForEach(layout.pages.indices, id: \.self) { index in
                    Circle().fill(index == page ? TildeColor.accent : TildeColor.text3.opacity(0.5)).frame(width: 4, height: 4)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(TildeColor.surface, in: RoundedRectangle(cornerRadius: TildeRadius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Key bar preview, page \(page + 1) of \(layout.pages.count)")
    }
}

private struct PreviewKey: View {
    let label: String
    let alternate: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(label)
                .font(TildeFont.mono(13, weight: .medium))
                .foregroundStyle(TildeColor.text)
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let alternate {
                Text(alternate)
                    .font(TildeFont.mono(8))
                    .foregroundStyle(TildeColor.text3)
                    .padding(.top, 2).padding(.trailing, 3)
            }
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity)
        .background(TildeColor.surface2, in: RoundedRectangle(cornerRadius: TildeRadius.key))
    }
}

private struct SlotRow: View {
    let slot: KeySlot

    var body: some View {
        HStack(spacing: 12) {
            Text(slot.displayLabel)
                .font(TildeFont.mono(15, weight: .semibold))
                .frame(width: 52, height: 30)
                .background(TildeColor.surface2, in: RoundedRectangle(cornerRadius: TildeRadius.key))
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.primary.accessibilityLabel).foregroundStyle(TildeColor.text)
                if let alternate = slot.alternate {
                    Text("Flick up: \(alternate.accessibilityLabel)").font(.footnote).foregroundStyle(TildeColor.text3)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(TildeColor.text3)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Slot editor and key catalog

private struct SlotEditor: View {
    @Binding var slot: KeySlot
    let tmuxPrefix: String
    @Environment(\.dismiss) private var dismiss
    @State private var target: Target = .primary

    enum Target: String, CaseIterable, Identifiable {
        case primary = "Key", alternate = "Flick up"
        var id: String { rawValue }
    }

    var body: some View {
        TildeSheet("Edit key", subtitle: "Pick what this slot sends", scrolls: false, idealHeight: 640) {
            VStack(spacing: 0) {
                Picker("Editing", selection: $target) {
                    ForEach(Target.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(TildeSheetMetrics.padding)
                HStack {
                    Text(target == .primary ? slot.displayLabel : (slot.displayAlternateLabel ?? "none"))
                        .font(TildeFont.mono(20, weight: .semibold))
                        .foregroundStyle(TildeColor.text)
                    if target == .alternate, slot.alternate != nil {
                        Spacer()
                        Button("Remove", role: .destructive) { slot.alternate = nil; slot.alternateLabel = nil }
                            .buttonStyle(.tildeSheetDestructive)
                    }
                }
                .padding(.horizontal, TildeSheetMetrics.padding)
                KeyCatalog { action in
                    if target == .primary {
                        slot.primary = action
                        slot.label = nil
                    } else {
                        slot.alternate = action
                        slot.alternateLabel = nil
                    }
                }
            }
        } actions: {
            TildeDefaultButton("Done") { dismiss() }
        }
        .preferredColorScheme(.dark)
    }
}

/// Everything a slot can send: ASCII characters, special keys, Ctrl combos, modifiers, literal text, snippets, tmux prefix,
/// paste and hide keyboard.
private struct KeyCatalog: View {
    let choose: (KeyAction) -> Void
    @State private var literal = ""

    private let ascii: [String] = (0x21...0x7E).map { String(UnicodeScalar($0)!) }
    private let special: [KeyAction] = [
        .key(.escape), .key(.tab), .key(.tab, modifiers: .shift), .key(.enter), .key(.backspace), .key(.delete), .key(.insert),
        .key(.home), .key(.end), .key(.pageUp), .key(.pageDown), .key(.up), .key(.down), .key(.left), .key(.right),
    ]
    private let functionKeys: [KeyAction] = (1...24).map { .key(NamedKey.function($0)!) }
    private let ctrls: [KeyAction] = "abcdefghijklmnopqrstuvwxyz".map { .ctrl(String($0)) }
    private let columns = [GridItem(.adaptive(minimum: 46), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                group("Characters") { grid(ascii.map { .text($0) } + [.text(" ")]) }
                group("Special keys") { grid(special) }
                group("Function keys") { grid(functionKeys) }
                group("Control combinations") { grid(ctrls) }
                group("Modifiers") { grid([.modifier(.ctrl), .modifier(.alt), .modifier(.shift)]) }
                group("Send text") {
                    HStack {
                        TextField("", text: $literal, prompt: Text("e.g. | grep -i ").foregroundStyle(TildeColor.text3))
                            .textFieldStyle(.plain)
                            .font(TildeFont.mono(14))
                            .noAutocapitalization()
                            .autocorrectionDisabled()
                            .padding(8)
                            .background(TildeColor.surface3, in: RoundedRectangle(cornerRadius: TildeRadius.key))
                        Button("Use") { choose(.text(literal)) }.disabled(literal.isEmpty)
                    }
                }
                group("Actions") { grid([.snippets, .tmuxPrefix, .paste, .hideKeyboard]) }
            }
            .padding()
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).tildeSectionHeader()
            content()
        }
    }

    private func grid(_ actions: [KeyAction]) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button { choose(action) } label: {
                    Text(action.defaultLabel)
                        .font(TildeFont.mono(14, weight: .medium))
                        .foregroundStyle(TildeColor.text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(TildeColor.surface2, in: RoundedRectangle(cornerRadius: TildeRadius.key))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.accessibilityLabel)
            }
        }
    }
}

#Preview("Key bar editor") {
    @Previewable @State var layout = KeyBarLayout.devOps
    return NavigationStack { KeyBarLayoutEditor(layout: $layout) }
}
