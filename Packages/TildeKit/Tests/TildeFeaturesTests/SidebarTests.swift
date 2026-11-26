import Foundation
import SwiftUI
import Testing
import TildeCore
import TildeStore
@testable import TildeFeatures

// MARK: - ServerListing

private struct StubServer: ServerListable, Equatable {
    var listID = UUID()
    var listDisplayName: String
    var listName: String
    var listSortIndex: Double = 0
    var listLastConnectedAt: Date?
    var listIsFavorite = false
    var listGroupID: UUID?
    var listSearchItem: ServerSearchItem

    init(_ name: String, host: String = "10.0.0.1", index: Double = 0, used: Date? = nil, favorite: Bool = false,
         group: UUID? = nil, tags: [String] = [], env: ServerEnvironment = .none, rawName: String? = nil) {
        listDisplayName = name
        listName = rawName ?? name
        listSortIndex = index
        listLastConnectedAt = used
        listIsFavorite = favorite
        listGroupID = group
        listSearchItem = ServerSearchItem(name: name, host: host, username: "deploy", tags: tags, groupName: nil, environment: env)
    }
}

@Suite struct ServerListingTests {
    private func names(_ servers: [StubServer]) -> [String] { servers.map(\.listDisplayName) }

    @Test func manualOrderUsesSortIndexThenRawName() {
        let list = [StubServer("c", index: 2), StubServer("b", index: 1), StubServer("z-display", index: 1, rawName: "a")]
        #expect(names(ServerListing.sorted(list, mode: .manual)) == ["z-display", "b", "c"])
    }

    @Test func nameOrderIsNaturalAndIgnoresIndex() {
        let list = [StubServer("web10", index: 0), StubServer("web2", index: 5), StubServer("api", index: 9)]
        #expect(names(ServerListing.sorted(list, mode: .name)) == ["api", "web2", "web10"])
    }

    @Test func lastUsedOrderPutsNeverUsedLast() {
        let list = [
            StubServer("never"),
            StubServer("old", used: Date(timeIntervalSince1970: 100)),
            StubServer("new", used: Date(timeIntervalSince1970: 200)),
        ]
        #expect(names(ServerListing.sorted(list, mode: .lastUsed)) == ["new", "old", "never"])
    }

    @Test(arguments: ServerSortMode.allCases)
    func favoritesFloatToTheTopUnderEveryMode(mode: ServerSortMode) {
        let list = [
            StubServer("a", index: 0, used: Date(timeIntervalSince1970: 300)),
            StubServer("b", index: 1, used: Date(timeIntervalSince1970: 200), favorite: true),
            StubServer("c", index: 2, used: Date(timeIntervalSince1970: 100), favorite: true),
        ]
        let plain = names(ServerListing.sorted(list, mode: mode))
        let floated = names(ServerListing.sorted(list, mode: mode, favoritesFirst: true))
        #expect(Set(floated.prefix(2)) == ["b", "c"])
        #expect(floated.last == "a")
        // Inside each half the order is the mode's own.
        #expect(floated.filter { $0 != "a" } == plain.filter { $0 != "a" })
    }

    @Test func rankedKeepsBestMatchFirstAndBreaksTiesByName() {
        let list = [StubServer("db-replica"), StubServer("db-primary"), StubServer("cache"), StubServer("adb")]
        let result = ServerListing.ranked(list, query: ServerQuery(parsing: "db"))
        // Prefix matches beat the substring match; the two prefix matches are ordered by name.
        #expect(names(result) == ["db-primary", "db-replica", "adb"])
    }

    @Test func rankedAppliesTagAndEnvironmentFilters() {
        let list = [StubServer("a", tags: ["k8s"], env: .prod), StubServer("b", tags: ["k8s"], env: .dev), StubServer("c", env: .prod)]
        #expect(names(ServerListing.ranked(list, query: ServerQuery(parsing: "#k8s env:prod"))) == ["a"])
    }

    @Test func filteredKeepsTheOriginalOrder() {
        let list = [StubServer("z", env: .prod), StubServer("a", env: .dev), StubServer("m", env: .prod)]
        #expect(names(ServerListing.filtered(list, query: ServerQuery(parsing: "env:prod"))) == ["z", "m"])
        #expect(names(ServerListing.filtered(list, query: ServerQuery(parsing: ""))) == ["z", "a", "m"])
    }

    @Test func everyServerLandsInExactlyOneSection() {
        let prod = UUID(), lab = UUID(), vanished = UUID()
        let list = [
            StubServer("p1", group: prod), StubServer("p2", index: 1, favorite: true, group: prod),
            StubServer("l1", group: lab), StubServer("loose"),
            // The group was not synced yet (or was deleted on another device): the server must not disappear.
            StubServer("orphan", group: vanished),
        ]
        let sections = ServerListing.sections(list, groupIDs: [prod, lab, UUID()], mode: .manual, favoritesFirst: true)
        #expect(names(sections.groups[prod] ?? []) == ["p2", "p1"])
        #expect(names(sections.groups[lab] ?? []) == ["l1"])
        #expect(Set(names(sections.ungrouped)) == ["loose", "orphan"])
        let total = sections.groups.values.reduce(0) { $0 + $1.count } + sections.ungrouped.count
        #expect(total == list.count)
    }

    @Test func emptyGroupsStayPresent() {
        let group = UUID()
        let sections = ServerListing.sections([StubServer("a")], groupIDs: [group], mode: .name, favoritesFirst: false)
        #expect(sections.groups[group]?.isEmpty == true)
        #expect(names(sections.ungrouped) == ["a"])
    }

    // MARK: Quick Connect

    @Test func targetLookingTextIsOfferedAsAConnection() {
        #expect(ServerListing.looksLikeTarget("deploy@10.0.4.12:2222"))
        #expect(ServerListing.looksLikeTarget("example.com"))
        #expect(ServerListing.looksLikeTarget("host:2222"))
        #expect(ServerListing.looksLikeTarget("ssh -p 22 box"))
        #expect(!ServerListing.looksLikeTarget("prod"))
    }

    @Test func returnConnectsWhenTheTextIsATargetWithAUserOrPort() {
        // A user or port means the text is a target even when a saved server also matches.
        #expect(ServerListing.submission(hasCandidate: true, rawText: "deploy@db", hasResults: true) == .connect)
        #expect(ServerListing.submission(hasCandidate: true, rawText: "db:2222", hasResults: true) == .connect)
        // Nothing else matches: connect.
        #expect(ServerListing.submission(hasCandidate: true, rawText: "example.com", hasResults: false) == .connect)
        // A dotted name that also matches a saved server opens the server.
        #expect(ServerListing.submission(hasCandidate: true, rawText: "example.com", hasResults: true) == .openFirstResult)
        #expect(ServerListing.submission(hasCandidate: false, rawText: "db", hasResults: true) == .openFirstResult)
        #expect(ServerListing.submission(hasCandidate: false, rawText: "zzz", hasResults: false) == .nothing)
    }

    @Test func theUntrimmedTextDecidesTheSubmission() {
        // `submit()` looks at the text as typed, so a lone trailing space does not change the answer.
        #expect(ServerListing.submission(hasCandidate: true, rawText: "a@b ", hasResults: true) == .connect)
    }
}

// MARK: - Sync footer

#if os(macOS)
@Suite struct SidebarSyncSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func summary(_ status: SyncStatus?, lastSync: Date? = nil) -> SidebarSyncSummary {
        SidebarSyncSummary(status: status, lastSync: lastSync, now: now)
    }

    @Test func noMonitorOrSyncOffMeansLocal() {
        #expect(summary(nil).text == "On this Mac")
        #expect(summary(.disabled).text == "On this Mac")
        #expect(!summary(.disabled).needsAttention)
    }

    @Test func accountProblemsAskForAttention() {
        for status in [SyncStatus.noAccount, .restricted, .temporarilyUnavailable, .error("boom")] {
            #expect(summary(status).needsAttention)
            #expect(summary(status).text.hasPrefix("iCloud"))
        }
        // CloudKit's own error text can be long and technical; it stays out of the footer.
        #expect(!summary(.error("boom")).text.contains("boom"))
    }

    @Test func upToDateShowsHowLongAgo() {
        #expect(summary(.upToDate).text == "iCloud · up to date")
        #expect(summary(.upToDate, lastSync: now.addingTimeInterval(-10)).text == "iCloud · synced just now")
        let later = summary(.upToDate, lastSync: now.addingTimeInterval(-300)).text
        #expect(later.hasPrefix("iCloud · synced ") && later != "iCloud · synced just now")
        #expect(summary(.syncing).text == "iCloud · syncing…")
        #expect(!summary(.upToDate).needsAttention)
    }

    @Test func iCloudAvailabilityMatchesOnboarding() {
        #expect(!SidebarSyncSummary.isAvailable(.disabled))
        #expect(!SidebarSyncSummary.isAvailable(.noAccount))
        #expect(!SidebarSyncSummary.isAvailable(.restricted))
        #expect(SidebarSyncSummary.isAvailable(.upToDate))
        #expect(SidebarSyncSummary.isAvailable(.syncing))
        #expect(SidebarSyncSummary.isAvailable(.temporarilyUnavailable))
        #expect(SidebarSyncSummary.isAvailable(.error("x")))
    }

    @Test func tagTokensMatchCaseInsensitively() {
        #expect(SidebarTagToken(name: "K8s") == SidebarTagToken(name: "k8S"))
        #expect(Set([SidebarTagToken(name: "Edge"), SidebarTagToken(name: "edge")]).count == 1)
        #expect(SidebarTagToken(name: "Edge").id == "edge")
    }
}
#endif

// MARK: - Sidebar auto-hide policy

@MainActor
@Suite struct SidebarPolicyTests {
    let window = UUID()

    private func makeNavigator(remembers: Bool = true) -> (SessionCoordinator, AppNavigator) {
        var services = TildeServices.preview
        services.sessionEngine = FakeSessionEngine(failure: nil, connectDelay: .milliseconds(1))
        let coordinator = SessionCoordinator(services: services, hostKeyTimeout: .seconds(120))
        let navigator = coordinator.navigator(for: window)
        navigator.remembersManualSidebarShow = remembers
        return (coordinator, navigator)
    }

    @Test func openingASessionHidesTheSidebar() {
        let (_, navigator) = makeNavigator()
        navigator.open(PreviewServers.prodAPI)
        #expect(navigator.columnVisibility == .detailOnly)
    }

    @Test func aSidebarShownByHandStaysUpForLaterSessions() {
        let (_, navigator) = makeNavigator()
        navigator.open(PreviewServers.prodAPI)
        navigator.toggleSidebar()
        #expect(navigator.columnVisibility == .all)
        navigator.open(PreviewServers.dbPrimary)
        #expect(navigator.columnVisibility == .all)
        navigator.open(PreviewServers.prodAPI, newSession: true)
        #expect(navigator.columnVisibility == .all)
    }

    @Test func reopeningTheSameServerDoesNotHideAShownSidebar() {
        let (coordinator, navigator) = makeNavigator()
        navigator.open(PreviewServers.prodAPI)
        navigator.columnVisibility = .all
        // Same server: the coordinator returns the existing tab, so the tab count does not change.
        navigator.open(PreviewServers.prodAPI)
        #expect(coordinator.tabs(in: window).count == 1)
        #expect(navigator.columnVisibility == .all)
    }

    @Test func hidingItAgainByHandIsRespected() {
        let (_, navigator) = makeNavigator()
        navigator.open(PreviewServers.prodAPI)
        navigator.toggleSidebar()
        navigator.toggleSidebar()
        #expect(navigator.columnVisibility == .detailOnly)
        // The user showed it once, so a later session still leaves their choice alone until the tabs close.
        navigator.toggleSidebar()
        navigator.open(PreviewServers.dbPrimary)
        #expect(navigator.columnVisibility == .all)
    }

    @Test func theMemoryEndsWhenEveryTabHasClosed() {
        let (coordinator, navigator) = makeNavigator()
        navigator.open(PreviewServers.prodAPI)
        navigator.columnVisibility = .all
        coordinator.closeAll()
        // SessionContainer brings the list back when the last tab closes.
        navigator.columnVisibility = .all
        navigator.open(PreviewServers.prodAPI)
        #expect(navigator.columnVisibility == .detailOnly)
    }

    @Test func theMemoryEndsEvenWhenNothingWritesTheVisibilityAfterTheLastTab() {
        let (coordinator, navigator) = makeNavigator()
        navigator.open(PreviewServers.prodAPI)
        navigator.columnVisibility = .all
        coordinator.closeAll()
        navigator.open(PreviewServers.dbPrimary)
        #expect(navigator.columnVisibility == .detailOnly)
    }

    @Test func reopeningAClosedTabFollowsTheSameRule() {
        let (coordinator, navigator) = makeNavigator()
        navigator.open(PreviewServers.prodAPI)
        navigator.columnVisibility = .all
        coordinator.closeAll()
        navigator.reopenLastClosed()
        #expect(navigator.columnVisibility == .detailOnly)
    }

    @Test func layoutEchoesAreNotAManualShow() {
        let (_, navigator) = makeNavigator()
        navigator.open(PreviewServers.prodAPI)
        // The app hid it; the split view writing visible values over visible values must not count.
        navigator.columnVisibility = .detailOnly
        navigator.columnVisibility = .detailOnly
        navigator.open(PreviewServers.dbPrimary)
        #expect(navigator.columnVisibility == .detailOnly)
    }

    @Test func showingItWithNoTabsIsNotRemembered() {
        let (_, navigator) = makeNavigator()
        navigator.columnVisibility = .detailOnly
        navigator.columnVisibility = .all
        navigator.open(PreviewServers.prodAPI)
        #expect(navigator.columnVisibility == .detailOnly)
    }

    @Test func iPadKeepsHidingEverySession() {
        let (_, navigator) = makeNavigator(remembers: false)
        navigator.open(PreviewServers.prodAPI)
        navigator.columnVisibility = .all
        navigator.open(PreviewServers.dbPrimary)
        #expect(navigator.columnVisibility == .detailOnly)
    }

    @Test func theCompactLayoutNeverTouchesTheSidebar() {
        let (_, navigator) = makeNavigator()
        navigator.isCompact = true
        navigator.open(PreviewServers.prodAPI)
        #expect(navigator.isDeckPresented)
        #expect(navigator.columnVisibility == .all)
    }

    #if os(macOS)
    @Test func quickConnectBringsTheHiddenSidebarBackWithoutRememberingIt() {
        let (_, navigator) = makeNavigator()
        navigator.open(PreviewServers.prodAPI)
        #expect(navigator.columnVisibility == .detailOnly)
        let token = navigator.focusSearchToken
        navigator.focusSearch()
        #expect(navigator.columnVisibility == .all)
        #expect(navigator.focusSearchToken == token + 1)
        // Connecting from the search field hides it again: it was summoned for typing, not re-shown for good.
        navigator.open(PreviewServers.dbPrimary)
        #expect(navigator.columnVisibility == .detailOnly)
    }

    @Test func quickConnectKeepsAnEarlierManualShow() {
        let (_, navigator) = makeNavigator()
        navigator.open(PreviewServers.prodAPI)
        navigator.columnVisibility = .all
        navigator.columnVisibility = .detailOnly
        navigator.focusSearch()
        navigator.open(PreviewServers.dbPrimary)
        // The sidebar stays hidden and was shown by hand before, so the memory is still honoured.
        #expect(navigator.columnVisibility == .all)
    }
    #endif
}
