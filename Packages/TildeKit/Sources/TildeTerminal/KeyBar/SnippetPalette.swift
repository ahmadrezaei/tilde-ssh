import SwiftUI
import TildeCore
import TildeDesign

/// Placeholder handling for snippets like `systemctl status <unit>`.
enum SnippetPlaceholders {
    /// Distinct placeholder names in order of appearance.
    static func names(in command: String) -> [String] {
        var seen: [String] = []
        for match in matches(in: command) where !seen.contains(match.name) { seen.append(match.name) }
        return seen
    }

    /// The command with every `<name>` replaced by its value (an empty value keeps the placeholder text).
    static func fill(_ command: String, values: [String: String]) -> String {
        var result = command
        for match in matches(in: command).reversed() {
            guard let value = values[match.name], !value.isEmpty else { continue }
            result.replaceSubrange(match.range, with: value)
        }
        return result
    }

    private static func matches(in command: String) -> [(name: String, range: Range<String.Index>)] {
        guard let regex = try? NSRegularExpression(pattern: "<([A-Za-z][A-Za-z0-9_\\- ]{0,30})>") else { return [] }
        let ns = command as NSString
        return regex.matches(in: command, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let whole = Range(m.range, in: command), let name = Range(m.range(at: 1), in: command) else { return nil }
            return (String(command[name]), whole)
        }
    }
}

extension View {
    /// Turns off auto-capitalisation where the platform has it (iOS).
    @ViewBuilder func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

/// Subsequence ("fuzzy") match score: nil when `query` is not a subsequence of `text`; higher is better.
enum FuzzyMatch {
    static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased()), t = Array(text.lowercased())
        guard !q.isEmpty else { return 0 }
        var qi = 0, score = 0, lastMatch = -2
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += 1
            if ti == lastMatch + 1 { score += 3 }                       // consecutive
            if ti == 0 || t[ti - 1] == " " || t[ti - 1] == "-" { score += 2 }   // word start
            lastMatch = ti
            qi += 1
        }
        return qi == q.count ? score : nil
    }
}

/// The snippet palette that opens above the key bar: fuzzy search, tap to insert, the return button to insert and run.
struct SnippetPaletteView: View {
    let provider: any SnippetProviding
    /// Called with the final command and whether to press Return.
    let onChoose: (String, Bool) -> Void
    let onCancel: () -> Void

    @State private var all: [SnippetSnapshot] = []
    @State private var query = ""
    @State private var pending: PendingSnippet?
    @FocusState private var searchFocused: Bool

    struct PendingSnippet: Identifiable {
        let id = UUID()
        let snippet: SnippetSnapshot
        let run: Bool
        let names: [String]
    }

    private var results: [SnippetSnapshot] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all
            .compactMap { s -> (SnippetSnapshot, Int)? in
                let best = [FuzzyMatch.score(q, in: s.name).map { $0 + 2 }, FuzzyMatch.score(q, in: s.command)].compactMap { $0 }.max()
                return best.map { (s, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let pending {
                PlaceholderForm(pending: pending, onChoose: onChoose, onBack: { self.pending = nil })
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").foregroundStyle(TildeColor.accent)
                    TextField("Snippets", text: $query)
                        .font(TildeFont.mono(14))
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                    Button("Close", action: onCancel).font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                Divider()
                if results.isEmpty {
                    Text(all.isEmpty ? "No snippets yet" : "No matches")
                        .font(TildeFont.caption).foregroundStyle(TildeColor.text3)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    List(results) { snippet in
                        HStack(spacing: 8) {
                            Button { choose(snippet, run: snippet.runOnInsert) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(snippet.name).font(TildeFont.mono(13, weight: .semibold)).foregroundStyle(TildeColor.text)
                                    Text(snippet.command).font(TildeFont.mono(11)).foregroundStyle(TildeColor.text2).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Insert \(snippet.name)")
                            Button { choose(snippet, run: true) } label: {
                                Image(systemName: "return").foregroundStyle(TildeColor.accent)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Insert \(snippet.name) and run")
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .background(TildeColor.surface)
        .task {
            all = await provider.snippets(matching: "")
            searchFocused = true
        }
    }

    private func choose(_ snippet: SnippetSnapshot, run: Bool) {
        let names = SnippetPlaceholders.names(in: snippet.command)
        if names.isEmpty {
            onChoose(snippet.command, run)
        } else {
            pending = PendingSnippet(snippet: snippet, run: run, names: names)
        }
    }
}

private struct PlaceholderForm: View {
    let pending: SnippetPaletteView.PendingSnippet
    let onChoose: (String, Bool) -> Void
    let onBack: () -> Void
    @State private var values: [String: String] = [:]
    @FocusState private var focus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { onBack() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back")
                Text(pending.snippet.name).font(TildeFont.mono(14, weight: .semibold))
                Spacer()
            }
            ForEach(pending.names, id: \.self) { name in
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(TildeFont.caption).foregroundStyle(TildeColor.text3)
                    TextField(name, text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
                        .font(TildeFont.mono(14))
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                        .focused($focus, equals: name)
                        .padding(8)
                        .background(TildeColor.surface3, in: RoundedRectangle(cornerRadius: TildeRadius.key))
                        .onSubmit { insert() }
                }
            }
            Text(SnippetPlaceholders.fill(pending.snippet.command, values: values))
                .font(TildeFont.mono(11)).foregroundStyle(TildeColor.text2).lineLimit(3)
            HStack {
                Button("Insert") { insert(run: false) }.buttonStyle(.bordered)
                Button("Insert and run") { insert(run: true) }.buttonStyle(.borderedProminent).tint(TildeColor.accentStrong)
            }
        }
        .padding(14)
        .onAppear { focus = pending.names.first }
    }

    private func insert() { insert(run: pending.run) }

    private func insert(run: Bool) {
        onChoose(SnippetPlaceholders.fill(pending.snippet.command, values: values), run)
    }
}

#if os(iOS)
import UIKit

/// Presents `SnippetPaletteView` as a popover from the snippet key (it stays a popover on iPhone too).
@MainActor
final class SnippetPalettePresenter: NSObject, UIPopoverPresentationControllerDelegate {
    private weak var presented: UIViewController?

    func present(from source: UIView, snippets: any SnippetProviding, onChoose: @escaping (String, Bool) -> Void) {
        guard presented == nil, let root = (source.window?.rootViewController ?? Self.appRoot)?.topmostPresented else { return }
        let dismiss: () -> Void = { [weak self] in self?.presented?.dismiss(animated: true) }
        let view = SnippetPaletteView(
            provider: snippets,
            onChoose: { command, run in
                dismiss()
                onChoose(command, run)
            },
            onCancel: dismiss
        )
        let controller = UIHostingController(rootView: view.preferredColorScheme(.dark))
        controller.modalPresentationStyle = .popover
        controller.preferredContentSize = CGSize(width: 340, height: 360)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = source
            popover.sourceRect = source.bounds
            popover.permittedArrowDirections = [.down, .up]
            popover.delegate = self
        }
        presented = controller
        root.present(controller, animated: true)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    private static var appRoot: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?.rootViewController
    }
}
#endif
