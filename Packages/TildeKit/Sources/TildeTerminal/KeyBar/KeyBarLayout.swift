import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What a key bar key does when tapped (or flicked).
///
/// Encoded flat as `{"kind": "text", "value": "/"}` so layout JSON stays readable and stable.
public struct KeyAction: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Types `value` (a character, or a literal string such as `| grep -i `). Modifiers apply to single characters.
        case text
        /// A named key (`value` is a `NamedKey` raw value) with optional extra `modifiers` (e.g. Shift-Tab).
        case key
        /// `Ctrl` + the character in `value` (`^C`).
        case ctrl
        /// A sticky modifier: `value` is `ctrl`, `alt` or `shift`.
        case modifier
        /// Opens the snippet palette.
        case snippets
        /// Sends the layout's tmux prefix (default `^B`).
        case tmuxPrefix
        /// Pastes the clipboard.
        case paste
        /// Dismisses the software keyboard.
        case hideKeyboard
    }

    public var kind: Kind
    public var value: String
    public var modifiers: KeyModifiers

    public init(kind: Kind, value: String = "", modifiers: KeyModifiers = []) {
        self.kind = kind
        self.value = value
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey { case kind, value, modifiers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        modifiers = try c.decodeIfPresent(KeyModifiers.self, forKey: .modifiers) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        if !value.isEmpty { try c.encode(value, forKey: .value) }
        if !modifiers.isEmpty { try c.encode(modifiers, forKey: .modifiers) }
    }

    // MARK: Constructors

    public static func text(_ string: String) -> KeyAction { KeyAction(kind: .text, value: string) }
    public static func key(_ key: NamedKey, modifiers: KeyModifiers = []) -> KeyAction {
        KeyAction(kind: .key, value: key.rawValue, modifiers: modifiers)
    }
    public static func ctrl(_ character: String) -> KeyAction { KeyAction(kind: .ctrl, value: character.lowercased()) }
    public static func modifier(_ modifier: KeyModifiers) -> KeyAction {
        KeyAction(kind: .modifier, value: modifier == .ctrl ? "ctrl" : modifier == .alt ? "alt" : "shift")
    }
    public static let snippets = KeyAction(kind: .snippets)
    public static let tmuxPrefix = KeyAction(kind: .tmuxPrefix)
    public static let paste = KeyAction(kind: .paste)
    public static let hideKeyboard = KeyAction(kind: .hideKeyboard)

    // MARK: Derived

    /// The named key, for `.key` actions.
    public var namedKey: NamedKey? { kind == .key ? NamedKey(rawValue: value) : nil }

    /// The sticky modifier, for `.modifier` actions.
    public var stickyModifier: KeyModifiers? {
        guard kind == .modifier else { return nil }
        switch value {
        case "ctrl": return .ctrl
        case "alt": return .alt
        case "shift": return .shift
        default: return nil
        }
    }

    /// Default label for a key cap.
    public var defaultLabel: String {
        switch kind {
        case .text:
            if value == " " { return "␣" }
            return value.count > 4 ? String(value.prefix(3)) + "…" : value
        case .key:
            if let key = namedKey {
                if key == .tab && modifiers.contains(.shift) { return "⇤" }
                return key.shortLabel
            }
            return value
        case .ctrl: return "^" + value.uppercased()
        case .modifier: return value
        case .snippets: return "⚡"
        case .tmuxPrefix: return "tmux"
        case .paste: return "paste"
        case .hideKeyboard: return "⌄"
        }
    }

    /// Spoken label for VoiceOver.
    public var accessibilityLabel: String {
        switch kind {
        case .text:
            let names: [String: String] = [
                " ": "Space", "/": "Slash", "\\": "Backslash", "-": "Hyphen", "_": "Underscore", "|": "Pipe", "~": "Tilde",
                "`": "Backtick", "&": "Ampersand", "{": "Left brace", "}": "Right brace", "[": "Left bracket",
                "]": "Right bracket", "<": "Less than", ">": "Greater than", "(": "Left parenthesis",
                ")": "Right parenthesis", "\"": "Double quote", "'": "Single quote", "=": "Equals", "+": "Plus",
                "$": "Dollar", "#": "Hash", "*": "Asterisk", "^": "Caret", ":": "Colon", ";": "Semicolon",
                "!": "Exclamation mark", "?": "Question mark", "@": "At sign", "%": "Percent", ".": "Period", ",": "Comma",
            ]
            return names[value] ?? value
        case .key:
            guard let key = namedKey else { return value }
            let names: [NamedKey: String] = [
                .escape: "Escape", .tab: "Tab", .enter: "Return", .backspace: "Backspace", .delete: "Delete",
                .insert: "Insert", .home: "Home", .end: "End", .pageUp: "Page up", .pageDown: "Page down",
                .up: "Up arrow", .down: "Down arrow", .left: "Left arrow", .right: "Right arrow",
            ]
            let base = names[key] ?? key.functionNumber.map { "F\($0)" } ?? value
            return modifiers.contains(.shift) ? "Shift " + base : base
        case .ctrl: return "Control \(value.uppercased())"
        case .modifier:
            switch value {
            case "ctrl": return "Control"
            case "alt": return "Alt"
            default: return "Shift"
            }
        case .snippets: return "Snippets"
        case .tmuxPrefix: return "tmux prefix"
        case .paste: return "Paste"
        case .hideKeyboard: return "Hide keyboard"
        }
    }
}

/// One slot on a key bar page: a key with an optional flick-up alternate.
public struct KeySlot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var primary: KeyAction
    /// Sent when the key is flicked up.
    public var alternate: KeyAction?
    /// Overrides the generated label of the key cap.
    public var label: String?
    /// Overrides the generated label of the alternate.
    public var alternateLabel: String?

    public init(_ primary: KeyAction, alternate: KeyAction? = nil, label: String? = nil, alternateLabel: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.primary = primary
        self.alternate = alternate
        self.label = label
        self.alternateLabel = alternateLabel
    }

    /// Convenience for the common "type a character, flick for another" key.
    public init(_ text: String, _ alternate: String? = nil) {
        self.init(.text(text), alternate: alternate.map { .text($0) })
    }

    public var displayLabel: String { label ?? primary.defaultLabel }
    public var displayAlternateLabel: String? { alternate.map { alternateLabel ?? $0.defaultLabel } }

    private enum CodingKeys: String, CodingKey { case primary, alternate, label, alternateLabel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        primary = try c.decode(KeyAction.self, forKey: .primary)
        alternate = try c.decodeIfPresent(KeyAction.self, forKey: .alternate)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        alternateLabel = try c.decodeIfPresent(String.self, forKey: .alternateLabel)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(primary, forKey: .primary)
        try c.encodeIfPresent(alternate, forKey: .alternate)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(alternateLabel, forKey: .alternateLabel)
    }

    /// Equality ignores `id`, which is regenerated on decode.
    public static func == (lhs: KeySlot, rhs: KeySlot) -> Bool {
        lhs.primary == rhs.primary && lhs.alternate == rhs.alternate && lhs.label == rhs.label && lhs.alternateLabel == rhs.alternateLabel
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(primary)
        hasher.combine(alternate)
        hasher.combine(label)
        hasher.combine(alternateLabel)
    }
}

/// One swipeable page of six keys.
public struct KeyBarPage: Codable, Hashable, Sendable, Identifiable {
    public static let slotCount = 6

    public var id: UUID
    public var name: String
    public var slots: [KeySlot]

    public init(name: String, slots: [KeySlot], id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.slots = Self.fit(slots)
    }

    private enum CodingKeys: String, CodingKey { case name, slots }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Page"
        slots = Self.fit(try c.decode([KeySlot].self, forKey: .slots))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(slots, forKey: .slots)
    }

    /// Equality ignores `id`, which is regenerated on decode.
    public static func == (lhs: KeyBarPage, rhs: KeyBarPage) -> Bool { lhs.name == rhs.name && lhs.slots == rhs.slots }
    public func hash(into hasher: inout Hasher) { hasher.combine(name); hasher.combine(slots) }

    /// Exactly six slots: extra ones are dropped, missing ones become a space key.
    private static func fit(_ slots: [KeySlot]) -> [KeySlot] {
        var s = Array(slots.prefix(slotCount))
        while s.count < slotCount { s.append(KeySlot(.text(" "))) }
        return s
    }
}

/// Versioned, syncable key bar layout (`KeyBarLayout v1`, docs/DESIGN.md section 5.5).
///
/// Esc and Ctrl are always pinned on the left; Alt is pinned unless `showsAlt` is false. The arrow joystick is pinned on the right.
public struct KeyBarLayout: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    public static let maxPages = 8

    public var version: Int
    public var presetName: String
    public var pages: [KeyBarPage]
    /// Shows Alt in the pinned zone.
    public var showsAlt: Bool
    /// The tmux prefix as a control letter (default `b`, i.e. `^B`).
    public var tmuxPrefix: String

    public init(version: Int = KeyBarLayout.currentVersion, presetName: String = "DevOps", pages: [KeyBarPage]? = nil, showsAlt: Bool = true, tmuxPrefix: String = "b") {
        self.version = version
        self.presetName = presetName
        self.pages = pages ?? Self.preset(named: presetName)?.pages ?? Self.devOpsPages
        self.showsAlt = showsAlt
        self.tmuxPrefix = tmuxPrefix
    }

    // MARK: Presets

    /// The default "DevOps" preset (docs/DESIGN.md section 5.2).
    public static let devOps = KeyBarLayout(presetName: "DevOps", pages: devOpsPages)
    public static let vim = KeyBarLayout(presetName: "Vim", pages: vimPages)
    public static let minimal = KeyBarLayout(presetName: "Minimal", pages: minimalPages)
    public static let tmux = KeyBarLayout(presetName: "tmux", pages: tmuxPages)
    public static let emacs = KeyBarLayout(presetName: "Emacs", pages: emacsPages)
    public static let kubernetes = KeyBarLayout(presetName: "Kubernetes", pages: kubernetesPages)

    /// All built-in presets, default first.
    public static let presets: [KeyBarLayout] = [.devOps, .vim, .minimal, .tmux, .emacs, .kubernetes]

    public static func preset(named name: String) -> KeyBarLayout? { presets.first { $0.presetName == name } }

    private static let nav = KeyBarPage(name: "Nav", slots: [
        KeySlot(.key(.home)), KeySlot(.key(.end)), KeySlot(.key(.pageUp)), KeySlot(.key(.pageDown)),
        KeySlot(.key(.delete)), KeySlot(.ctrl("w"), label: "⌫w"),
    ])
    private static let fKeys = KeyBarPage(name: "F-keys", slots: (1...6).map {
        KeySlot(.key(NamedKey.function($0)!), alternate: .key(NamedKey.function($0 + 6)!))
    })

    private static var devOpsPages: [KeyBarPage] {
        [
            KeyBarPage(name: "Core", slots: [
                KeySlot(.key(.tab), alternate: .key(.tab, modifiers: .shift)),
                KeySlot("/", "\\"), KeySlot("-", "_"), KeySlot("|", "&"), KeySlot("~", "`"),
                KeySlot(.snippets),
            ]),
            KeyBarPage(name: "Brackets", slots: [
                KeySlot("{", "}"), KeySlot("[", "]"), KeySlot("<", ">"), KeySlot("(", ")"), KeySlot("\"", "'"), KeySlot("=", "+"),
            ]),
            KeyBarPage(name: "Shell", slots: [
                KeySlot("$", "#"), KeySlot("*", "^"), KeySlot(":", ";"), KeySlot("!", "?"), KeySlot("@", "%"),
                KeySlot(.ctrl("c")),
            ]),
            nav,
            fKeys,
        ]
    }

    private static var vimPages: [KeyBarPage] {
        [
            KeyBarPage(name: "Motion", slots: [
                KeySlot(":", ";"), KeySlot("/", "?"), KeySlot("^", "$"), KeySlot("{", "}"), KeySlot("[", "]"), KeySlot("%", "#"),
            ]),
            KeyBarPage(name: "Scroll", slots: [
                KeySlot(.ctrl("u")), KeySlot(.ctrl("d")), KeySlot(.ctrl("f")), KeySlot(.ctrl("b")),
                KeySlot(.ctrl("r")), KeySlot(.ctrl("v")),
            ]),
            KeyBarPage(name: "Edit", slots: [
                KeySlot("\"", "'"), KeySlot("*", "&"), KeySlot("~", "`"), KeySlot("<", ">"), KeySlot("(", ")"), KeySlot("=", "+"),
            ]),
            KeyBarPage(name: "Core", slots: [
                KeySlot(.key(.tab), alternate: .key(.tab, modifiers: .shift)), KeySlot("-", "_"), KeySlot("|", "\\"),
                KeySlot("$", "@"), KeySlot(.ctrl("c")), KeySlot(.snippets),
            ]),
            nav,
        ]
    }

    private static var minimalPages: [KeyBarPage] {
        [
            KeyBarPage(name: "Core", slots: [
                KeySlot(.key(.tab), alternate: .key(.tab, modifiers: .shift)), KeySlot("/", "\\"), KeySlot("-", "_"),
                KeySlot("|", "&"), KeySlot("~", "`"), KeySlot(.snippets),
            ]),
        ]
    }

    private static var tmuxPages: [KeyBarPage] {
        [
            KeyBarPage(name: "tmux", slots: [
                KeySlot(.tmuxPrefix), KeySlot(.tmuxPrefix, alternate: .text("c"), label: "tmux", alternateLabel: "new"),
                KeySlot("n", "p"), KeySlot("d", "x"), KeySlot("[", "]"), KeySlot("%", "\""),
            ]),
            KeyBarPage(name: "Core", slots: [
                KeySlot(.key(.tab), alternate: .key(.tab, modifiers: .shift)), KeySlot("/", "\\"), KeySlot("-", "_"),
                KeySlot("|", "&"), KeySlot("~", "`"), KeySlot(.snippets),
            ]),
            nav,
        ]
    }

    private static var emacsPages: [KeyBarPage] {
        [
            KeyBarPage(name: "Chords", slots: [
                KeySlot(.ctrl("x")), KeySlot(.ctrl("g")), KeySlot(.ctrl("s")), KeySlot(.ctrl("a")), KeySlot(.ctrl("e")),
                KeySlot(.ctrl("k")),
            ]),
            KeyBarPage(name: "Core", slots: [
                KeySlot(.key(.tab), alternate: .key(.tab, modifiers: .shift)), KeySlot("/", "\\"), KeySlot("-", "_"),
                KeySlot("|", "&"), KeySlot("~", "`"), KeySlot(.snippets),
            ]),
            nav,
        ]
    }

    private static var kubernetesPages: [KeyBarPage] {
        [
            KeyBarPage(name: "kubectl", slots: [
                KeySlot(.text("kubectl "), label: "k"), KeySlot(.text("-n "), label: "-n"), KeySlot(.text("-o wide"), label: "-o"),
                KeySlot(.text("--all-namespaces "), label: "-A"), KeySlot(.text(" | grep "), label: "|g"),
                KeySlot(.text("logs -f "), label: "logs"),
            ]),
            KeyBarPage(name: "Core", slots: [
                KeySlot(.key(.tab), alternate: .key(.tab, modifiers: .shift)), KeySlot("/", "\\"), KeySlot("-", "_"),
                KeySlot("|", "&"), KeySlot("~", "`"), KeySlot(.snippets),
            ]),
            nav,
        ]
    }

    // MARK: JSON

    /// Normalizes the layout (1...8 pages, never empty).
    public func normalized() -> KeyBarLayout {
        var copy = self
        if copy.pages.isEmpty { copy.pages = Self.devOpsPages }
        if copy.pages.count > Self.maxPages { copy.pages = Array(copy.pages.prefix(Self.maxPages)) }
        if copy.tmuxPrefix.count != 1 { copy.tmuxPrefix = "b" }
        return copy
    }

    /// JSON for storage and `.tildekeys` export.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads a layout from JSON, rejecting versions this build does not know.
    public static func decode(from data: Data) throws -> KeyBarLayout {
        let layout = try JSONDecoder().decode(KeyBarLayout.self, from: data)
        guard layout.version <= currentVersion else { throw KeyBarLayoutError.unsupportedVersion(layout.version) }
        return layout.normalized()
    }

    private enum CodingKeys: String, CodingKey { case version, presetName, pages, showsAlt, tmuxPrefix }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        presetName = try c.decodeIfPresent(String.self, forKey: .presetName) ?? "Custom"
        pages = try c.decode([KeyBarPage].self, forKey: .pages)
        showsAlt = try c.decodeIfPresent(Bool.self, forKey: .showsAlt) ?? true
        tmuxPrefix = try c.decodeIfPresent(String.self, forKey: .tmuxPrefix) ?? "b"
    }
}

public enum KeyBarLayoutError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}

// MARK: - Persistence

/// Where the key bar layout lives. The default is `UserDefaults`; the app can swap in a store backed by
/// `NSUbiquitousKeyValueStore` (owned by the sync layer) without touching the terminal code.
public protocol KeyBarLayoutStoring: Sendable {
    func load() -> KeyBarLayout?
    func save(_ layout: KeyBarLayout)
}

/// `UserDefaults` backed store. iPhone and iPad keep separate layouts, so the key includes `scope`.
public struct UserDefaultsKeyBarLayoutStore: KeyBarLayoutStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameters:
    ///   - scope: a name for the device class (`"phone"`, `"pad"`, `"mac"`), so layouts do not mix.
    public init(defaults: UserDefaults = .standard, scope: String) {
        self.defaults = defaults
        self.key = "tilde.keybar.layout.v1.\(scope)"
    }

    /// The scope for this device: `phone`, `pad` or `mac`.
    @MainActor public static func currentScope() -> String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
        #else
        "mac"
        #endif
    }

    /// A store for this device class.
    @MainActor public static func current(defaults: UserDefaults = .standard) -> UserDefaultsKeyBarLayoutStore {
        UserDefaultsKeyBarLayoutStore(defaults: defaults, scope: currentScope())
    }

    public func load() -> KeyBarLayout? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? KeyBarLayout.decode(from: data)
    }

    public func save(_ layout: KeyBarLayout) {
        guard let data = try? layout.jsonData() else { return }
        defaults.set(data, forKey: key)
    }
}
