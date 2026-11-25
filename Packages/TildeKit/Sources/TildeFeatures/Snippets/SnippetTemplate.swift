import Foundation
import TildeCore
import TildeStore

/// `<placeholder>` handling for snippets: `sudo journalctl -u <unit> -f` asks for `unit` before it is typed.
enum SnippetTemplate {
    /// The distinct placeholder names, in order of first appearance.
    static func placeholders(in command: String) -> [String] {
        var names: [String] = []
        for token in tokens(in: command) {
            if case .placeholder(let name) = token, !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Replaces each `<name>` that has a non-empty value; others stay as they are.
    static func fill(_ command: String, values: [String: String]) -> String {
        tokens(in: command).map { token in
            switch token {
            case .text(let text): text
            case .placeholder(let name): values[name].flatMap { $0.isEmpty ? nil : $0 } ?? "<\(name)>"
            }
        }.joined()
    }

    private enum Token {
        case text(String)
        case placeholder(String)
    }

    private static func isNameStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
    private static func isNameBody(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" }

    private static func tokens(in command: String) -> [Token] {
        var result: [Token] = []
        var text = ""
        var index = command.startIndex
        while index < command.endIndex {
            let ch = command[index]
            if ch == "<", let close = closingIndex(in: command, after: index) {
                if !text.isEmpty { result.append(.text(text)); text = "" }
                result.append(.placeholder(String(command[command.index(after: index)..<close])))
                index = command.index(after: close)
                continue
            }
            text.append(ch)
            index = command.index(after: index)
        }
        if !text.isEmpty { result.append(.text(text)) }
        return result
    }

    /// The index of the `>` closing a valid `<name>` that starts at `open`.
    private static func closingIndex(in command: String, after open: String.Index) -> String.Index? {
        var i = command.index(after: open)
        guard i < command.endIndex, isNameStart(command[i]) else { return nil }
        while i < command.endIndex {
            if command[i] == ">" { return i }
            guard isNameBody(command[i]) else { return nil }
            i = command.index(after: i)
        }
        return nil
    }
}

extension Snippet {
    var runsOnInsert: Bool { runModeRaw == "insertAndReturn" }

    var snapshot: SnippetSnapshot {
        SnippetSnapshot(id: id, name: name, command: command, runOnInsert: runsOnInsert)
    }
}
