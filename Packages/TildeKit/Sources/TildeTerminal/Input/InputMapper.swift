import Foundation

/// Modifier keys the terminal understands. Raw values are the xterm modifier bits (`param = 1 + bits`).
public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1)
    public static let alt = KeyModifiers(rawValue: 2)
    public static let ctrl = KeyModifiers(rawValue: 4)

    /// The xterm modifier parameter used in `CSI 1 ; <param> A` style sequences.
    public var xtermParameter: Int { 1 + (rawValue & 7) }
}

/// A key that is not a printable character.
public enum NamedKey: String, Codable, Hashable, Sendable, CaseIterable {
    case escape, tab, enter, backspace, delete, insert
    case home, end, pageUp, pageDown
    case up, down, left, right
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case f13, f14, f15, f16, f17, f18, f19, f20, f21, f22, f23, f24

    /// `1...24` for function keys, nil otherwise.
    public var functionNumber: Int? {
        guard rawValue.hasPrefix("f") else { return nil }
        return Int(rawValue.dropFirst())
    }

    /// The function key `F<n>` for `n` in `1...24`.
    public static func function(_ n: Int) -> NamedKey? {
        guard (1...24).contains(n) else { return nil }
        return NamedKey(rawValue: "f\(n)")
    }

    /// Short label for UI ("esc", "pgup", "F5").
    public var shortLabel: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .enter: "ret"
        case .backspace: "bksp"
        case .delete: "del"
        case .insert: "ins"
        case .home: "home"
        case .end: "end"
        case .pageUp: "pgup"
        case .pageDown: "pgdn"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        default: functionNumber.map { "F\($0)" } ?? rawValue
        }
    }
}

/// What a key press is: a named key or typed text.
public enum TerminalKey: Hashable, Sendable {
    case named(NamedKey)
    case text(String)
}

/// Terminal modes that change what keys send.
public struct TerminalInputModes: Equatable, Sendable {
    /// DECCKM: arrows, Home and End send `SS3` (`ESC O x`) instead of `CSI` (`ESC [ x`).
    public var applicationCursor: Bool
    /// Backspace sends `^H` (0x08) instead of DEL (0x7F).
    public var backspaceSendsControlH: Bool

    public init(applicationCursor: Bool = false, backspaceSendsControlH: Bool = false) {
        self.applicationCursor = applicationCursor
        self.backspaceSendsControlH = backspaceSendsControlH
    }

    public static let normal = TerminalInputModes()
}

/// Byte-exact key to escape-sequence mapping (xterm-256color), see docs/DESIGN.md section 5.3.
///
/// Rules:
/// - Ctrl + letter is the control character (`a` is 0x01). `@ [ \ ] ^ _ ? space` and `/` follow xterm,
///   digits `2...8` map to `NUL ESC FS GS RS US DEL`. Anything else is sent unchanged.
/// - Alt sends an ESC prefix (`ESC` + the key's bytes).
/// - Modified cursor and editing keys use the xterm form `CSI 1 ; m X` / `CSI n ; m ~`, in both cursor modes.
/// - F13...F24 are shifted F1...F12, matching the terminfo entry of `xterm-256color`.
public enum InputMapper {
    private static let esc: UInt8 = 0x1B

    // Pre-built sequences: unmodified keys return shared storage, so a key press does not allocate.
    private static let csiUp: [UInt8] = [0x1B, 0x5B, 0x41], csiDown: [UInt8] = [0x1B, 0x5B, 0x42]
    private static let csiRight: [UInt8] = [0x1B, 0x5B, 0x43], csiLeft: [UInt8] = [0x1B, 0x5B, 0x44]
    private static let ss3Up: [UInt8] = [0x1B, 0x4F, 0x41], ss3Down: [UInt8] = [0x1B, 0x4F, 0x42]
    private static let ss3Right: [UInt8] = [0x1B, 0x4F, 0x43], ss3Left: [UInt8] = [0x1B, 0x4F, 0x44]
    private static let csiHome: [UInt8] = [0x1B, 0x5B, 0x48], csiEnd: [UInt8] = [0x1B, 0x5B, 0x46]
    private static let ss3Home: [UInt8] = [0x1B, 0x4F, 0x48], ss3End: [UInt8] = [0x1B, 0x4F, 0x46]
    private static let escByte: [UInt8] = [0x1B], tabByte: [UInt8] = [0x09], enterByte: [UInt8] = [0x0D]
    private static let del7F: [UInt8] = [0x7F], bs08: [UInt8] = [0x08]
    private static let backTab: [UInt8] = [0x1B, 0x5B, 0x5A]
    private static let tildeFinal = UInt8(ascii: "~")

    /// The bytes a key sends. `modifiers` are the active Shift/Alt/Ctrl.
    public static func bytes(for key: TerminalKey, modifiers: KeyModifiers = [], modes: TerminalInputModes = .normal) -> [UInt8] {
        switch key {
        case .named(let named): return bytes(for: named, modifiers: modifiers, modes: modes)
        case .text(let text): return bytes(forText: text, modifiers: modifiers)
        }
    }

    /// Bytes for a named key.
    public static func bytes(for key: NamedKey, modifiers: KeyModifiers = [], modes: TerminalInputModes = .normal) -> [UInt8] {
        let ctrl = modifiers.contains(.ctrl), alt = modifiers.contains(.alt), shift = modifiers.contains(.shift)
        switch key {
        case .escape:
            return alt ? [esc, esc] : escByte
        case .tab:
            let base = shift ? backTab : tabByte
            return alt ? [esc] + base : base
        case .enter:
            return alt ? [esc, 0x0D] : enterByte
        case .backspace:
            // Ctrl+Backspace is ^H in xterm; Alt prefixes ESC (readline backward-kill-word).
            let byte = (ctrl || modes.backspaceSendsControlH) ? bs08 : del7F
            return alt ? [esc] + byte : byte
        case .up, .down, .left, .right, .home, .end:
            return cursorKey(key, modifiers: modifiers, modes: modes)
        case .delete: return tildeKey(3, modifiers)
        case .insert: return tildeKey(2, modifiers)
        case .pageUp: return tildeKey(5, modifiers)
        case .pageDown: return tildeKey(6, modifiers)
        default:
            guard let n = key.functionNumber else { return [] }
            return functionKey(n, modifiers: modifiers)
        }
    }

    /// Bytes for typed text. Modifier combinations apply to a single character; longer strings are sent as typed
    /// (Alt still adds one ESC prefix).
    public static func bytes(forText text: String, modifiers: KeyModifiers = []) -> [UInt8] {
        guard !text.isEmpty else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count + 1)
        if modifiers.contains(.alt) { out.append(esc) }
        var source = text
        if modifiers.contains(.shift), text.count == 1 { source = shifted(text) }
        if modifiers.contains(.ctrl), let byte = controlByte(for: source) {
            out.append(byte)
        } else {
            out.append(contentsOf: source.utf8)
        }
        return out
    }

    /// The control character for `Ctrl+character`, or nil when xterm sends the character unchanged.
    public static func controlByte(for text: String) -> UInt8? {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, scalar.isASCII else { return nil }
        let v = UInt8(scalar.value)
        switch v {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"): return v & 0x1F
        case UInt8(ascii: "@"), UInt8(ascii: " "), UInt8(ascii: "2"): return 0x00
        case UInt8(ascii: "["), UInt8(ascii: "3"): return 0x1B
        case UInt8(ascii: "\\"), UInt8(ascii: "4"): return 0x1C
        case UInt8(ascii: "]"), UInt8(ascii: "5"): return 0x1D
        case UInt8(ascii: "^"), UInt8(ascii: "6"): return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "7"), UInt8(ascii: "/"): return 0x1F
        case UInt8(ascii: "?"), UInt8(ascii: "8"): return 0x7F
        default: return nil
        }
    }

    /// Applies Shift to a single character on a US layout (letters, number row and punctuation pairs).
    public static func shifted(_ text: String) -> String {
        guard text.count == 1 else { return text }
        let pairs: [Character: Character] = [
            "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
            "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
        ]
        if let mapped = pairs[text[text.startIndex]] { return String(mapped) }
        return text.uppercased()
    }

    // MARK: Sequences

    private static func cursorKey(_ key: NamedKey, modifiers: KeyModifiers, modes: TerminalInputModes) -> [UInt8] {
        if modifiers.isEmpty {
            if modes.applicationCursor {
                switch key {
                case .up: return ss3Up
                case .down: return ss3Down
                case .right: return ss3Right
                case .left: return ss3Left
                case .home: return ss3Home
                default: return ss3End
                }
            }
            switch key {
            case .up: return csiUp
            case .down: return csiDown
            case .right: return csiRight
            case .left: return csiLeft
            case .home: return csiHome
            default: return csiEnd
            }
        }
        let final: UInt8
        switch key {
        case .up: final = UInt8(ascii: "A")
        case .down: final = UInt8(ascii: "B")
        case .right: final = UInt8(ascii: "C")
        case .left: final = UInt8(ascii: "D")
        case .home: final = UInt8(ascii: "H")
        default: final = UInt8(ascii: "F")
        }
        return [esc, 0x5B, 0x31, 0x3B] + decimal(modifiers.xtermParameter) + [final]
    }

    private static func tildeKey(_ code: Int, _ modifiers: KeyModifiers) -> [UInt8] {
        var out: [UInt8] = [esc, 0x5B]
        out += decimal(code)
        if !modifiers.isEmpty {
            out.append(0x3B)
            out += decimal(modifiers.xtermParameter)
        }
        out.append(tildeFinal)
        return out
    }

    private static func functionKey(_ n: Int, modifiers: KeyModifiers) -> [UInt8] {
        var number = n
        var mods = modifiers
        if n > 12 {   // xterm-256color terminfo: kf13 is shifted F1, ..., kf24 is shifted F12
            number = n - 12
            mods.insert(.shift)
        }
        if (1...4).contains(number) {
            let final = UInt8(ascii: "P") + UInt8(number - 1)
            if mods.isEmpty { return [esc, 0x4F, final] }
            return [esc, 0x5B, 0x31, 0x3B] + decimal(mods.xtermParameter) + [final]
        }
        let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
        return tildeKey(codes[number] ?? 24, mods)
    }

    private static func decimal(_ value: Int) -> [UInt8] { Array(String(value).utf8) }
}
