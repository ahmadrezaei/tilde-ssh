import Testing
import TildeCore
import TildeDesign
@testable import TildeFeatures

@Suite struct SessionChromeTests {
    @Test func subtitleOmitsTheDefaultPort() {
        let target = ConnectionTarget(host: "10.0.1.12", port: 22, username: "deploy")
        #expect(SessionContainer.subtitle(for: target) == "deploy@10.0.1.12")
    }

    @Test func subtitleShowsANonDefaultPort() {
        let target = ConnectionTarget(host: "127.0.0.1", port: 2201, username: "pwuser")
        #expect(SessionContainer.subtitle(for: target) == "pwuser@127.0.0.1:2201")
    }

    @Test func latencyQualityBoundaries() {
        #expect(StatusReadout.Quality(latencyMilliseconds: 0) == .good)
        #expect(StatusReadout.Quality(latencyMilliseconds: 149) == .good)
        #expect(StatusReadout.Quality(latencyMilliseconds: 150) == .slow)
        #expect(StatusReadout.Quality(latencyMilliseconds: 499) == .slow)
        #expect(StatusReadout.Quality(latencyMilliseconds: 500) == .bad)
    }

    @Test func tabHintsFollowTheShortcutMapping() {
        // Up to eight tabs: each tab shows its own digit, and nothing claims the 9.
        #expect(TabStripHint.digit(forTab: 1, of: 3) == 1)
        #expect(TabStripHint.digit(forTab: 8, of: 8) == 8)
        // Nine or more: the 9 jumps to the last tab, so the middle ones past 8 have no hint.
        #expect(TabStripHint.digit(forTab: 8, of: 12) == 8)
        #expect(TabStripHint.digit(forTab: 9, of: 12) == nil)
        #expect(TabStripHint.digit(forTab: 12, of: 12) == 9)
        #expect(TabStripHint.digit(forTab: 9, of: 9) == 9)
        // Every hint agrees with the menu's mapping.
        for count in 1...12 {
            for tab in 1...count {
                if let digit = TabStripHint.digit(forTab: tab, of: count) {
                    #expect(TabShortcut.index(forDigit: digit, tabCount: count) == tab - 1)
                }
            }
        }
    }
}
