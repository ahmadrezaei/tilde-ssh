#if os(macOS)
import AppKit
import SwiftUI

/// Tags as native tokens: type a word, press Return or comma, and it turns into a removable token (`NSTokenField`).
/// The binding follows every keystroke, so a half-typed tag is already in the list when a button is clicked.
public struct TildeTokenField: NSViewRepresentable {
    @Binding private var tokens: [String]
    @Binding private var isFocused: Bool
    private let prompt: String
    private let suggestions: [String]

    /// - Parameters:
    ///   - suggestions: existing tags offered as completions.
    ///   - isFocused: `true` while the field has keyboard focus (the editor stops Return from reaching a default
    ///     button then, because Return belongs to the field).
    public init(tokens: Binding<[String]>, prompt: String = "", suggestions: [String] = [], isFocused: Binding<Bool> = .constant(false)) {
        self._tokens = tokens
        self._isFocused = isFocused
        self.prompt = prompt
        self.suggestions = suggestions
    }

    /// Trims, drops empties and repeats (ignoring case), keeping the first spelling and the order.
    public static func normalized(_ values: [Any]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for case let value as String in values {
            let token = value.trimmingCharacters(in: CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines))
            guard !token.isEmpty, seen.insert(token.lowercased()).inserted else { continue }
            result.append(token)
        }
        return result
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> FocusReportingTokenField {
        let field = FocusReportingTokenField()
        field.delegate = context.coordinator
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = prompt
        field.lineBreakMode = .byTruncatingTail
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.setFocused(focused) }
        field.objectValue = tokens
        return field
    }

    public func updateNSView(_ field: FocusReportingTokenField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = prompt
        // While the user types, the field is the source of truth; replacing its value would move the caret.
        guard field.currentEditor() == nil else { return }
        let current = Self.normalized((field.objectValue as? [Any]) ?? [])
        if current != tokens { field.objectValue = tokens }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusReportingTokenField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: max(nsView.fittingSize.height, 22))
    }

    @MainActor
    public final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TildeTokenField

        init(_ parent: TildeTokenField) { self.parent = parent }

        func setFocused(_ focused: Bool) {
            // Focus can change in the middle of a view update; publish it on the next turn.
            Task { @MainActor in
                if parent.isFocused != focused { parent.isFocused = focused }
            }
        }

        public func controlTextDidChange(_ notification: Notification) { sync(notification) }

        public func controlTextDidEndEditing(_ notification: Notification) {
            sync(notification)
            // Show the cleaned list (repeats removed) once the user is done typing.
            if let field = notification.object as? NSTokenField, TildeTokenField.normalized((field.objectValue as? [Any]) ?? []) != parent.tokens {
                field.objectValue = parent.tokens
            }
            setFocused(false)
        }

        private func sync(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let updated = TildeTokenField.normalized((field.objectValue as? [Any]) ?? [])
            if updated != parent.tokens { parent.tokens = updated }
        }

        /// Repeats are removed in `sync`; checking here would compare a new token with the text it was made from.
        public func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            tokens.filter { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        }

        public func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
                               indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            parent.suggestions.filter { $0.localizedCaseInsensitiveContains(substring) }
        }
    }
}

/// An `NSTokenField` that tells its owner when it gains keyboard focus, which `controlTextDidBeginEditing` only does
/// after the first keystroke.
public final class FocusReportingTokenField: NSTokenField {
    var onFocusChange: ((Bool) -> Void)?

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
}
#endif
