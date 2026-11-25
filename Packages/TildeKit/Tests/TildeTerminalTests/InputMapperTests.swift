import Testing
@testable import TildeTerminal

/// Byte-exact checks for every key in every mode. Expected values are written as escaped strings so a
/// failure reads like the escape sequence it is about.
@Suite struct InputMapperTests {
    private func bytes(_ key: NamedKey, _ mods: KeyModifiers = [], app: Bool = false, bsH: Bool = false) -> [UInt8] {
        InputMapper.bytes(for: key, modifiers: mods, modes: TerminalInputModes(applicationCursor: app, backspaceSendsControlH: bsH))
    }
    private func text(_ s: String, _ mods: KeyModifiers = []) -> [UInt8] { InputMapper.bytes(forText: s, modifiers: mods) }
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: Plain keys

    @Test func plainKeys() {
        #expect(bytes(.escape) == [0x1B])
        #expect(bytes(.tab) == [0x09])
        #expect(bytes(.enter) == [0x0D])
        #expect(bytes(.backspace) == [0x7F])
        #expect(bytes(.backspace, bsH: true) == [0x08])
        #expect(bytes(.delete) == b("\u{1B}[3~"))
        #expect(bytes(.insert) == b("\u{1B}[2~"))
        #expect(bytes(.pageUp) == b("\u{1B}[5~"))
        #expect(bytes(.pageDown) == b("\u{1B}[6~"))
    }

    // MARK: Cursor keys: normal vs application (DECCKM)

    @Test func cursorKeysNormalMode() {
        #expect(bytes(.up) == b("\u{1B}[A"))
        #expect(bytes(.down) == b("\u{1B}[B"))
        #expect(bytes(.right) == b("\u{1B}[C"))
        #expect(bytes(.left) == b("\u{1B}[D"))
        #expect(bytes(.home) == b("\u{1B}[H"))
        #expect(bytes(.end) == b("\u{1B}[F"))
    }

    @Test func cursorKeysApplicationMode() {
        #expect(bytes(.up, app: true) == b("\u{1B}OA"))
        #expect(bytes(.down, app: true) == b("\u{1B}OB"))
        #expect(bytes(.right, app: true) == b("\u{1B}OC"))
        #expect(bytes(.left, app: true) == b("\u{1B}OD"))
        #expect(bytes(.home, app: true) == b("\u{1B}OH"))
        #expect(bytes(.end, app: true) == b("\u{1B}OF"))
    }

    @Test func pageAndEditingKeysIgnoreApplicationMode() {
        #expect(bytes(.pageUp, app: true) == b("\u{1B}[5~"))
        #expect(bytes(.delete, app: true) == b("\u{1B}[3~"))
    }

    @Test func modifiedCursorKeysUseCSIFormInBothModes() {
        for app in [false, true] {
            #expect(bytes(.up, .ctrl, app: app) == b("\u{1B}[1;5A"))
            #expect(bytes(.down, .alt, app: app) == b("\u{1B}[1;3B"))
            #expect(bytes(.right, .shift, app: app) == b("\u{1B}[1;2C"))
            #expect(bytes(.left, [.ctrl, .alt], app: app) == b("\u{1B}[1;7D"))
            #expect(bytes(.home, .ctrl, app: app) == b("\u{1B}[1;5H"))
            #expect(bytes(.end, [.shift, .ctrl, .alt], app: app) == b("\u{1B}[1;8F"))
        }
    }

    @Test func modifiedEditingKeys() {
        #expect(bytes(.delete, .ctrl) == b("\u{1B}[3;5~"))
        #expect(bytes(.pageUp, .alt) == b("\u{1B}[5;3~"))
        #expect(bytes(.pageDown, .shift) == b("\u{1B}[6;2~"))
        #expect(bytes(.insert, [.ctrl, .shift]) == b("\u{1B}[2;6~"))
    }

    // MARK: Function keys

    @Test func functionKeys() {
        let expected = [
            "\u{1B}OP", "\u{1B}OQ", "\u{1B}OR", "\u{1B}OS", "\u{1B}[15~", "\u{1B}[17~", "\u{1B}[18~", "\u{1B}[19~",
            "\u{1B}[20~", "\u{1B}[21~", "\u{1B}[23~", "\u{1B}[24~",
        ]
        for (index, sequence) in expected.enumerated() {
            #expect(bytes(NamedKey.function(index + 1)!) == b(sequence), "F\(index + 1)")
        }
    }

    @Test func functionKeysIgnoreApplicationCursorMode() {
        #expect(bytes(.f1, app: true) == b("\u{1B}OP"))
        #expect(bytes(.f5, app: true) == b("\u{1B}[15~"))
    }

    @Test func modifiedFunctionKeys() {
        #expect(bytes(.f1, .ctrl) == b("\u{1B}[1;5P"))
        #expect(bytes(.f4, .shift) == b("\u{1B}[1;2S"))
        #expect(bytes(.f5, .ctrl) == b("\u{1B}[15;5~"))
        #expect(bytes(.f12, [.alt]) == b("\u{1B}[24;3~"))
    }

    @Test func f13ToF24AreShiftedF1ToF12() {
        #expect(bytes(.f13) == b("\u{1B}[1;2P"))
        #expect(bytes(.f16) == b("\u{1B}[1;2S"))
        #expect(bytes(.f17) == b("\u{1B}[15;2~"))
        #expect(bytes(.f24) == b("\u{1B}[24;2~"))
        #expect(bytes(.f13, .ctrl) == b("\u{1B}[1;6P"))
    }

    @Test func functionNumbers() {
        #expect(NamedKey.f1.functionNumber == 1)
        #expect(NamedKey.f24.functionNumber == 24)
        #expect(NamedKey.up.functionNumber == nil)
        #expect(NamedKey.function(0) == nil)
        #expect(NamedKey.function(25) == nil)
    }

    // MARK: Alt = ESC prefix

    @Test func altPrefixesEscape() {
        #expect(text("b", .alt) == [0x1B, 0x62])
        #expect(text("f", .alt) == [0x1B, 0x66])
        #expect(text(".", .alt) == [0x1B, 0x2E])
        #expect(bytes(.backspace, .alt) == [0x1B, 0x7F])
        #expect(bytes(.enter, .alt) == [0x1B, 0x0D])
        #expect(bytes(.tab, .alt) == [0x1B, 0x09])
        #expect(bytes(.escape, .alt) == [0x1B, 0x1B])
        #expect(text("é", .alt) == [0x1B, 0xC3, 0xA9])
    }

    @Test func altOnMultiCharacterTextPrefixesOnce() {
        #expect(text("ls", .alt) == [0x1B, 0x6C, 0x73])
    }

    // MARK: Ctrl

    @Test func ctrlLetters() {
        for (i, ch) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            #expect(text(String(ch), .ctrl) == [UInt8(i + 1)], "Ctrl+\(ch)")
            #expect(text(String(ch).uppercased(), .ctrl) == [UInt8(i + 1)], "Ctrl+\(ch.uppercased())")
        }
    }

    @Test func ctrlPunctuationFollowsXterm() {
        #expect(text("@", .ctrl) == [0x00])
        #expect(text(" ", .ctrl) == [0x00])
        #expect(text("[", .ctrl) == [0x1B])
        #expect(text("\\", .ctrl) == [0x1C])
        #expect(text("]", .ctrl) == [0x1D])
        #expect(text("^", .ctrl) == [0x1E])
        #expect(text("_", .ctrl) == [0x1F])
        #expect(text("/", .ctrl) == [0x1F])
        #expect(text("?", .ctrl) == [0x7F])
    }

    @Test func ctrlDigitsFollowXterm() {
        #expect(text("2", .ctrl) == [0x00])
        #expect(text("3", .ctrl) == [0x1B])
        #expect(text("4", .ctrl) == [0x1C])
        #expect(text("5", .ctrl) == [0x1D])
        #expect(text("6", .ctrl) == [0x1E])
        #expect(text("7", .ctrl) == [0x1F])
        #expect(text("8", .ctrl) == [0x7F])
        #expect(text("0", .ctrl) == [0x30])
        #expect(text("1", .ctrl) == [0x31])
        #expect(text("9", .ctrl) == [0x39])
    }

    @Test func ctrlWithoutMappingSendsCharacterUnchanged() {
        #expect(text("-", .ctrl) == [0x2D])
        #expect(text("é", .ctrl) == [0xC3, 0xA9])
        #expect(text("😀", .ctrl) == Array("😀".utf8))
    }

    @Test func ctrlAltCombines() {
        #expect(text("c", [.ctrl, .alt]) == [0x1B, 0x03])
        #expect(text("[", [.ctrl, .alt]) == [0x1B, 0x1B])
    }

    @Test func ctrlBackspaceIsControlH() {
        #expect(bytes(.backspace, .ctrl) == [0x08])
        #expect(bytes(.backspace, [.ctrl, .alt]) == [0x1B, 0x08])
    }

    @Test func ctrlOnMultiCharacterTextIsLiteral() {
        #expect(text("ab", .ctrl) == b("ab"))
    }

    // MARK: Shift

    @Test func shiftTab() {
        #expect(bytes(.tab, .shift) == b("\u{1B}[Z"))
        #expect(bytes(.tab, [.shift, .alt]) == b("\u{1B}\u{1B}[Z"))
    }

    @Test func shiftedText() {
        #expect(text("a", .shift) == b("A"))
        #expect(text("1", .shift) == b("!"))
        #expect(text("/", .shift) == b("?"))
        #expect(text("-", .shift) == b("_"))
        #expect(text("`", .shift) == b("~"))
        #expect(text("a", [.shift, .ctrl]) == [0x01])
    }

    // MARK: Plain text

    @Test func plainTextIsUTF8() {
        #expect(text("a") == [0x61])
        #expect(text("é") == [0xC3, 0xA9])
        #expect(text("| grep -i ") == b("| grep -i "))
        #expect(text("").isEmpty)
    }

    @Test func terminalKeyDispatch() {
        #expect(InputMapper.bytes(for: .named(.up), modifiers: [], modes: TerminalInputModes(applicationCursor: true)) == b("\u{1B}OA"))
        #expect(InputMapper.bytes(for: .text("c"), modifiers: .ctrl) == [0x03])
    }

    @Test func everyNamedKeyProducesBytes() {
        for key in NamedKey.allCases {
            for mods in [KeyModifiers(), .ctrl, .alt, .shift, [.ctrl, .alt, .shift]] {
                #expect(!bytes(key, mods).isEmpty, "\(key) \(mods)")
                #expect(bytes(key, mods).first == 0x1B || [.tab, .enter, .backspace].contains(key), "\(key)")
            }
        }
    }
}
