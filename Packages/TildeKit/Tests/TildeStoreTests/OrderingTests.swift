import Foundation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

@Suite struct FractionalOrderTests {
    private final class Item { var index: Double; let name: String; init(_ name: String, _ index: Double) { self.name = name; self.index = index } }

    private func items(_ names: String...) -> [Item] { names.enumerated().map { Item($1, Double($0 + 1) * FractionalOrder.step) } }
    private func order(_ items: [Item]) -> [String] { items.sorted { $0.index < $1.index }.map(\.name) }

    @Test func indexBetween() {
        #expect(FractionalOrder.index(after: nil, before: nil) == FractionalOrder.step)
        #expect(FractionalOrder.index(after: 10, before: nil) == 10 + FractionalOrder.step)
        #expect(FractionalOrder.index(after: nil, before: 10) == 10 - FractionalOrder.step)
        #expect(FractionalOrder.index(after: 10, before: 20) == 15)
    }

    @Test func moveDownRewritesOnlyTheMovedItem() {
        let list = items("a", "b", "c", "d")
        let before = list.map(\.index)
        let changed = FractionalOrder.move(list, fromOffsets: IndexSet(integer: 0), toOffset: 3, index: { $0.index }, setIndex: { $0.index = $1 })
        #expect(order(list) == ["b", "c", "a", "d"])
        #expect(changed.map(\.name) == ["a"])
        #expect(list.map(\.index).enumerated().filter { $0.element != before[$0.offset] }.count == 1)
    }

    @Test func moveUpAndToEnds() {
        var list = items("a", "b", "c", "d")
        FractionalOrder.move(list, fromOffsets: IndexSet(integer: 3), toOffset: 0, index: { $0.index }, setIndex: { $0.index = $1 })
        #expect(order(list) == ["d", "a", "b", "c"])
        list = items("a", "b", "c", "d")
        FractionalOrder.move(list, fromOffsets: IndexSet(integer: 0), toOffset: 4, index: { $0.index }, setIndex: { $0.index = $1 })
        #expect(order(list) == ["b", "c", "d", "a"])
    }

    @Test func movingSeveralItemsKeepsTheirRelativeOrder() {
        let list = items("a", "b", "c", "d", "e")
        FractionalOrder.move(list, fromOffsets: IndexSet([0, 1]), toOffset: 4, index: { $0.index }, setIndex: { $0.index = $1 })
        #expect(order(list) == ["c", "d", "a", "b", "e"])
    }

    @Test func outOfRangeOffsetsAreIgnored() {
        let list = items("a", "b")
        let changed = FractionalOrder.move(list, fromOffsets: IndexSet(integer: 9), toOffset: 0, index: { $0.index }, setIndex: { $0.index = $1 })
        #expect(changed.isEmpty)
        #expect(order(list) == ["a", "b"])
    }

    @Test func repeatedBisectionRebalancesInsteadOfLosingPrecision() {
        let list = items("a", "b", "c")
        var rebalanced = false
        for round in 0..<200 {
            // Always move the last item to just after "a": the gap right after "a" halves every round.
            let sorted = list.sorted { $0.index < $1.index }
            let changed = FractionalOrder.move(sorted, fromOffsets: IndexSet(integer: 2), toOffset: 1, index: { $0.index }, setIndex: { $0.index = $1 })
            rebalanced = rebalanced || changed.count == 3
            #expect(order(list).first == "a", "round \(round)")
        }
        #expect(rebalanced, "the list was renumbered once the gap ran out")
        #expect(Set(list.map(\.index)).count == 3, "indices stay distinct")
    }

    @Test func insertAtPosition() {
        let list = items("a", "b", "c")
        let x = Item("x", 0)
        FractionalOrder.insert(x, at: 1, among: list, index: { $0.index }, setIndex: { $0.index = $1 })
        #expect(order(list + [x]) == ["a", "x", "b", "c"])
        let y = Item("y", 0)
        FractionalOrder.insert(y, at: 0, among: list, index: { $0.index }, setIndex: { $0.index = $1 })
        #expect(order(list + [y]).first == "y")
    }
}

@MainActor
@Suite struct ServerOrderingTests {
    @Test func addAppendsWithinTheGroup() throws {
        let container = try makeContainer()
        let repo = ServerRepository(context: container.mainContext)
        let groups = GroupRepository(context: container.mainContext)
        let prod = try groups.add(name: "Prod")
        let a = try repo.add(Server(name: "a", host: "a", username: "u"))
        let b = try repo.add(Server(name: "b", host: "b", username: "u"))
        let p1 = Server(name: "p1", host: "p1", username: "u")
        p1.group = prod
        try repo.add(p1)
        #expect(a.sortIndex < b.sortIndex)
        #expect(try repo.servers(in: nil).map(\.name) == ["a", "b"])
        #expect(try repo.servers(in: prod).map(\.name) == ["p1"])
    }

    @Test func reorderPersistsAndOnlyTouchesMovedServers() throws {
        let container = try makeContainer()
        let repo = ServerRepository(context: container.mainContext)
        let servers = try ["a", "b", "c", "d"].map { try repo.add(Server(name: $0, host: $0, username: "u")) }
        let stamps = servers.map(\.updatedAt)
        try repo.reorder(try repo.all(), fromOffsets: IndexSet(integer: 3), toOffset: 1)
        #expect(try repo.all().map(\.name) == ["a", "d", "b", "c"])
        #expect(servers[0].updatedAt == stamps[0] && servers[1].updatedAt == stamps[1])
        #expect(servers[3].updatedAt > stamps[3])
    }

    @Test func moveToGroupPlacesAtEndOrPosition() throws {
        let container = try makeContainer()
        let repo = ServerRepository(context: container.mainContext)
        let groups = GroupRepository(context: container.mainContext)
        let g = try groups.add(name: "G")
        let x = try repo.add(Server(name: "x", host: "x", username: "u"))
        let y = try repo.add(Server(name: "y", host: "y", username: "u"))
        let z = try repo.add(Server(name: "z", host: "z", username: "u"))
        try repo.move(x, to: g)
        try repo.move(y, to: g)
        try repo.move(z, to: g, at: 0)
        #expect(try repo.servers(in: g).map(\.name) == ["z", "x", "y"])
        try repo.move(z, to: nil)
        #expect(try repo.servers(in: nil).map(\.name) == ["z"])
    }

    @Test func groupAndSnippetReorder() throws {
        let container = try makeContainer()
        let groups = GroupRepository(context: container.mainContext)
        for name in ["A", "B", "C"] { try groups.add(name: name) }
        try groups.reorder(try groups.all(), fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(try groups.all().map(\.name) == ["C", "A", "B"])

        let snippets = SnippetRepository(context: container.mainContext)
        for name in ["one", "two", "three"] { try snippets.add(name: name, command: name) }
        try snippets.reorder(try snippets.all(), fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(try snippets.all().map(\.name) == ["two", "three", "one"])
        try snippets.setFavorite(try snippets.all()[2], true)
        #expect(try snippets.all().first?.name == "one", "favourites sort first")
    }
}
