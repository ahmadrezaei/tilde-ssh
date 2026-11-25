import Foundation
import Testing
@testable import TildeTerminal

@Suite struct KeyBarLayoutTests {
    @Test func devOpsPresetMatchesDesign() {
        let layout = KeyBarLayout.devOps
        #expect(layout.pages.count == 5)
        #expect(layout.pages.map(\.name) == ["Core", "Brackets", "Shell", "Nav", "F-keys"])
        for page in layout.pages { #expect(page.slots.count == 6) }
        let core = layout.pages[0].slots
        #expect(core[0].primary == .key(.tab))
        #expect(core[0].alternate == .key(.tab, modifiers: .shift))
        #expect(core[1].primary == .text("/") && core[1].alternate == .text("\\"))
        #expect(core[5].primary == .snippets)
        #expect(layout.pages[2].slots[5].primary == .ctrl("c"))
        #expect(layout.pages[4].slots[0].primary == .key(.f1) && layout.pages[4].slots[0].alternate == .key(.f7))
        #expect(layout.pages[4].slots[5].alternate == .key(.f12))
    }

    @Test func presetsExistAndAreWellFormed() {
        #expect(KeyBarLayout.presets.map(\.presetName).prefix(3) == ["DevOps", "Vim", "Minimal"])
        for preset in KeyBarLayout.presets {
            #expect(!preset.pages.isEmpty && preset.pages.count <= KeyBarLayout.maxPages, "\(preset.presetName)")
            for page in preset.pages { #expect(page.slots.count == KeyBarPage.slotCount) }
        }
        #expect(KeyBarLayout.minimal.pages.count == 1)
        #expect(KeyBarLayout().presetName == "DevOps")
    }

    @Test func jsonRoundTrip() throws {
        for preset in KeyBarLayout.presets {
            let data = try preset.jsonData()
            let decoded = try KeyBarLayout.decode(from: data)
            #expect(decoded == preset, "\(preset.presetName)")
        }
    }

    @Test func jsonIsFlatAndReadable() throws {
        let data = try KeyBarLayout.minimal.jsonData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"kind\" : \"text\""))
        #expect(text.contains("\"value\" : \"\\/\"") || text.contains("\"value\" : \"/\""))
        #expect(text.contains("\"version\" : 1"))
    }

    @Test func decodingFitsPagesToSixSlots() throws {
        let json = """
        {"version":1,"presetName":"X","pages":[{"name":"P","slots":[{"primary":{"kind":"text","value":"a"}}]}]}
        """
        let layout = try KeyBarLayout.decode(from: Data(json.utf8))
        #expect(layout.pages[0].slots.count == 6)
        #expect(layout.pages[0].slots[0].primary == .text("a"))
        #expect(layout.showsAlt)
        #expect(layout.tmuxPrefix == "b")
    }

    @Test func newerVersionIsRejected() {
        let json = #"{"version":99,"pages":[{"name":"P","slots":[]}]}"#
        #expect(throws: KeyBarLayoutError.unsupportedVersion(99)) { try KeyBarLayout.decode(from: Data(json.utf8)) }
    }

    @Test func garbageIsRejected() {
        #expect(throws: (any Error).self) { try KeyBarLayout.decode(from: Data("not json".utf8)) }
    }

    @Test func labels() {
        #expect(KeyAction.text("/").defaultLabel == "/")
        #expect(KeyAction.text(" ").defaultLabel == "␣")
        #expect(KeyAction.ctrl("c").defaultLabel == "^C")
        #expect(KeyAction.key(.tab, modifiers: .shift).defaultLabel == "⇤")
        #expect(KeyAction.key(.pageUp).defaultLabel == "pgup")
        #expect(KeyAction.snippets.defaultLabel == "⚡")
        #expect(KeyAction.text("/").accessibilityLabel == "Slash")
        #expect(KeyAction.ctrl("c").accessibilityLabel == "Control C")
        #expect(KeyAction.key(.tab, modifiers: .shift).accessibilityLabel == "Shift Tab")
    }

    @Test func storeRoundTripAndScopeIsolation() throws {
        let suite = "tilde.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let phone = UserDefaultsKeyBarLayoutStore(defaults: defaults, scope: "phone")
        let pad = UserDefaultsKeyBarLayoutStore(defaults: defaults, scope: "pad")
        #expect(phone.load() == nil)
        phone.save(.vim)
        #expect(phone.load() == .vim)
        #expect(pad.load() == nil)
    }

    @Test func normalizedClampsPages() {
        let many = KeyBarLayout(presetName: "Big", pages: Array(repeating: KeyBarPage(name: "p", slots: []), count: 12))
        #expect(many.normalized().pages.count == KeyBarLayout.maxPages)
        let empty = KeyBarLayout(presetName: "Empty", pages: [])
        #expect(!empty.normalized().pages.isEmpty)
    }
}
