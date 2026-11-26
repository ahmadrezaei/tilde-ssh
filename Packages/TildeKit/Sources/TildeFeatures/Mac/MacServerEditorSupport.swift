import Foundation
import TildeCore
import TildeDesign

// Logic behind the Mac server editor that is worth testing without a view. Compiles on every platform.

/// One `KEY=value` row of the environment variables table.
struct EnvVarRow: Identifiable, Equatable {
    var id = UUID()
    var key = ""
    var value = ""

    /// Rows for the model's `KEY=value` lines. A line without `=` becomes a key with no value.
    static func rows(from text: String) -> [EnvVarRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            guard let eq = trimmed.firstIndex(of: "=") else { return EnvVarRow(key: trimmed) }
            return EnvVarRow(key: String(trimmed[..<eq]), value: String(trimmed[trimmed.index(after: eq)...]))
        }
    }

    /// The text `ServerEditorModel.envVarsText` stores. Empty rows are skipped; a row with a value but no key is written
    /// as `=value`, which the model's own validation rejects, so Save stays off until it is fixed. `=` is dropped from
    /// keys and line breaks from both, because either would change what the line means.
    static func text(from rows: [EnvVarRow]) -> String {
        rows.compactMap { row in
            let key = row.key.filter { $0 != "=" && !$0.isNewline }.trimmingCharacters(in: .whitespaces)
            let value = String(row.value.filter { !$0.isNewline })
            if key.isEmpty, value.isEmpty { return nil }
            return "\(key)=\(value)"
        }
        .joined(separator: "\n")
    }

    /// Keys that appear more than once (the last one would win silently).
    static func duplicateKeys(in rows: [EnvVarRow]) -> Set<String> {
        let keys = rows.map { $0.key.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Set(Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys)
    }
}

extension ServerEditorModel {
    /// The command the form describes, for the footer: `ssh -p 2222 -J ops@bastion deploy@10.0.4.12`. Works while the
    /// form is half filled (the host reads `hostname` until one is typed).
    var sshPreview: String {
        SSHCommand.string(
            target: ConnectionTarget(host: trimmedHost.isEmpty ? "hostname" : trimmedHost, port: port ?? 22, username: effectiveUsername),
            jump: jump.map { ServerMapper.jump($0).target }
        )
    }

    /// `TERM` values offered in the pop-up; the server's current value is added when it is something else.
    static let termTypes = ["xterm-256color", "xterm", "screen-256color", "tmux-256color", "linux", "vt100"]

    var termChoices: [String] { Self.termTypes.contains(termType) ? Self.termTypes : [termType] + Self.termTypes }
}

/// Which button Return presses in the Mac editor. The design makes Return "Save & Connect". Connecting runs the startup
/// command on a server, so for PROD Return only saves and connecting takes a click. While a free-text field that uses
/// Return itself (tags, notes) has focus, Return belongs to the field.
enum MacEditorReturn {
    enum Action: Equatable { case saveAndConnect, save, none }

    static func action(environment: ServerEnvironment, isEditingFreeText: Bool) -> Action {
        if isEditingFreeText { return .none }
        return environment == .prod ? .save : .saveAndConnect
    }

    /// The look follows the environment, so it does not jump when focus moves; focus only takes Return away.
    static func saveRole(environment: ServerEnvironment, isEditingFreeText: Bool) -> TildeActionRole {
        guard environment == .prod else { return .secondary }
        return isEditingFreeText ? .confirmByClick : .confirm
    }

    static func saveAndConnectRole(environment: ServerEnvironment, isEditingFreeText: Bool) -> TildeActionRole {
        guard environment != .prod else { return .secondary }
        return isEditingFreeText ? .confirmByClick : .confirm
    }
}
