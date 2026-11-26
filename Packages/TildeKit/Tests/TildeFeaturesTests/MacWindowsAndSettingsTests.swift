import Foundation
import SwiftData
import Testing
import TildeCore
import TildeStore
@testable import TildeFeatures

/// The logic behind the Mac Settings window, the Keys / Snippets windows and the command palette's Mac polish.
@MainActor
@Suite struct MacWindowsAndSettingsTests {
    // MARK: Sheet routing

    @Test func keysSnippetsAndSettingsRouteToWindowsOnTheMac() {
        #expect(AppSheet.keys.macRoute == .window(.keys))
        #expect(AppSheet.snippets.macRoute == .window(.snippets))
        #expect(AppSheet.settings.macRoute == .settings)
    }

    @Test func everyOtherSheetStaysASheet() {
        let id = UUID()
        let sheets: [AppSheet] = [
            .newServer, .editServer(id), .palette(.all), .palette(.newTab), .palette(.snippets),
            .generateKey, .importSSHConfig, .importKnownHosts, .newSnippet, .editSnippet(id),
        ]
        for sheet in sheets { #expect(sheet.macRoute == .sheet) }
    }

    @Test func aRoutedValueDoesNotCountAsAShownSheet() {
        let coordinator = SessionCoordinator(services: TildeServices.preview)
        let navigator = coordinator.navigator(for: UUID())
        #expect(!navigator.isShowingSheet)
        navigator.present(.newServer)
        #expect(navigator.isShowingSheet)
        navigator.present(.keys)
        #expect(!navigator.isShowingSheet)
    }

    @Test func utilityWindowIDsAreDistinctAndTitled() {
        #expect(Set(UtilityWindow.allCases.map(\.id)).count == UtilityWindow.allCases.count)
        #expect(UtilityWindow.keys.title == "Keys")
        #expect(UtilityWindow.snippets.title == "Snippets")
    }

    // MARK: Settings panes

    @Test func settingsHasFivePanesInOrder() {
        #expect(SettingsPane.allCases.map(\.title) == ["General", "Terminal", "Security", "Sync", "Known Hosts"])
        for pane in SettingsPane.allCases {
            #expect(!pane.symbol.isEmpty)
            #expect(pane.size.width >= 500 && pane.size.height >= 300)
        }
    }

    // MARK: Known hosts table

    @Test func endpointsSplitIntoHostAndPort() {
        #expect(KnownHostTableRow.parse(endpoint: "example.com") == ("example.com", 22))
        #expect(KnownHostTableRow.parse(endpoint: "[example.com]:2222") == ("example.com", 2222))
        #expect(KnownHostTableRow.parse(endpoint: "::1") == ("::1", 22))
        #expect(KnownHostTableRow.parse(endpoint: "[::1]:2222") == ("::1", 2222))
        #expect(KnownHostTableRow.parse(endpoint: "[h]:x") == ("[h]:x", 22))
        #expect(KnownHostTableRow.parse(endpoint: "[h") == ("[h", 22))
        #expect(KnownHostTableRow.parse(endpoint: "[h]:0") == ("[h]:0", 22))
    }

    @Test func rowsAreSortedByHostThenPortAndLeaveOutForgottenPins() {
        let pins = [
            pin("[b.example]:2222", "ssh-ed25519", "SHA256:b2"),
            pin("b.example", "ssh-rsa", "SHA256:b1"),
            pin("a.example", "ssh-ed25519", "SHA256:a1"),
            pin("gone.example", "ssh-ed25519", "SHA256:g1", status: .revoked),
        ]
        let rows = KnownHostTableRow.rows(from: pins)
        #expect(rows.map(\.fingerprint) == ["SHA256:a1", "SHA256:b1", "SHA256:b2"])
        #expect(rows.map(\.port) == [22, 22, 2222])
        #expect(rows.map(\.keyType) == ["ED25519", "RSA", "ED25519"])
    }

    @Test func searchMatchesEndpointFingerprintAndAlgorithm() {
        let pins = [
            pin("db.example", "ssh-ed25519", "SHA256:AAA111"),
            pin("web.example", "ecdsa-sha2-nistp256", "SHA256:BBB222"),
        ]
        #expect(KnownHostTableRow.rows(from: pins, matching: "DB").map(\.host) == ["db.example"])
        #expect(KnownHostTableRow.rows(from: pins, matching: "bbb").map(\.host) == ["web.example"])
        #expect(KnownHostTableRow.rows(from: pins, matching: "ecdsa").map(\.host) == ["web.example"])
        #expect(KnownHostTableRow.rows(from: pins, matching: "  ").count == 2)
        #expect(KnownHostTableRow.rows(from: pins, matching: "nope").isEmpty)
    }

    @Test func aConflictedPinIsFlagged() {
        let rows = KnownHostTableRow.rows(from: [pin("a", "ssh-ed25519", "SHA256:x", status: .conflicted), pin("b", "ssh-ed25519", "SHA256:y")])
        #expect(rows.map(\.isConflicted) == [true, false])
    }

    @Test func removeNeverReachesSelectedRowsTheSearchHides() {
        let a = pin("a.example", "ssh-ed25519", "SHA256:a")
        let b = pin("b.example", "ssh-ed25519", "SHA256:b")
        let shown = KnownHostTableRow.rows(from: [a, b], matching: "b.example")
        #expect(KnownHostTableRow.visibleSelection([a.id, b.id], in: shown) == [b.id])
        #expect(KnownHostTableRow.visibleSelection([a.id], in: shown).isEmpty)
    }

    @Test func removingSeveralPinsForgetsEachOne() throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let context = container.mainContext
        let pins = [pin("a", "ssh-ed25519", "SHA256:a"), pin("b", "ssh-ed25519", "SHA256:b"), pin("c", "ssh-ed25519", "SHA256:c")]
        for pin in pins { context.insert(pin) }
        try context.save()
        let error = KnownHostRemoval.forget(ids: [pins[0].id, pins[2].id], from: pins, repository: KnownHostRepository(context: context))
        #expect(error == nil)
        #expect(try context.fetch(FetchDescriptor<KnownHost>()).map(\.endpoint) == ["b"])
    }

    // MARK: Palette shortcuts

    @Test func paletteActionsShowTheirMenuShortcuts() {
        #expect(PaletteShortcut.label(for: .newServer) == "⇧⌘N")
        #expect(PaletteShortcut.label(for: .settings) == "⌘,")
        #expect(PaletteShortcut.label(for: .keys) == "⌥⌘K")
        #expect(PaletteShortcut.label(for: .snippets) == "⌥⌘S")
        #expect(PaletteShortcut.label(for: .reopenClosed) == "⇧⌘T")
        #expect(PaletteShortcut.label(for: .generateKey) == nil)
        #expect(PaletteShortcut.label(for: .importConfig) == nil)
    }

    @Test func tabShortcutsFollowTheWindowMenuRule() {
        #expect(PaletteShortcut.label(forTabAt: 0, tabCount: 1) == "⌘1")
        #expect(PaletteShortcut.label(forTabAt: 8, tabCount: 9) == "⌘9")
        #expect(PaletteShortcut.label(forTabAt: 7, tabCount: 10) == "⌘8")
        #expect(PaletteShortcut.label(forTabAt: 8, tabCount: 10) == nil)
        #expect(PaletteShortcut.label(forTabAt: 9, tabCount: 10) == "⌘9")
        #expect(PaletteShortcut.label(forTabAt: 11, tabCount: 12) == "⌘9")
    }

    @Test func footerHintsFollowTheHighlightedRow() {
        func item(_ kind: PaletteItem.Kind) -> PaletteItem {
            PaletteItem(id: "x", kind: kind, section: .servers, title: "x", subtitle: nil, symbol: "x")
        }
        #expect(PaletteShortcut.hints(for: item(.server(UUID()))).map(\.keys) == ["↵", "⌘↵", "esc"])
        #expect(PaletteShortcut.hints(for: item(.server(UUID()))).map(\.title) == ["connect", "new tab", "close"])
        #expect(PaletteShortcut.hints(for: item(.action(.settings))).map(\.title) == ["run", "close"])
        #expect(PaletteShortcut.hints(for: item(.session(UUID()))).map(\.title) == ["switch", "close"])
        #expect(PaletteShortcut.hints(for: nil).map(\.title) == ["close"])
    }

    // MARK: Helpers

    private func pin(_ endpoint: String, _ algorithm: String, _ fingerprint: String, status: KnownHostStatus = .trusted) -> KnownHost {
        let pin = KnownHost(endpoint: endpoint, algorithm: algorithm, publicKeyBase64: "AAAA", fingerprintSHA256: fingerprint, trustedOnDevice: "Mac")
        pin.status = status
        return pin
    }
}
