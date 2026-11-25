import Foundation

/// Fractional `sortIndex` arithmetic for drag-to-reorder. CloudKit has no ordered relationships, so a
/// reorder rewrites only the moved records (see docs/DESIGN.md section 6.3), and the list is always read
/// back sorted by `sortIndex`.
public enum FractionalOrder {
    /// The distance between indices after a rebalance and for appends.
    public static let step: Double = 1024

    /// Below this gap two neighbours are too close to split again without losing precision.
    static let minimumGap: Double = 1e-6

    /// An index that sorts after `lower` and before `upper`. A missing bound means "open end".
    public static func index(after lower: Double?, before upper: Double?) -> Double {
        switch (lower, upper) {
        case (nil, nil): return step
        case let (lower?, nil): return lower + step
        case let (nil, upper?): return upper - step
        case let (lower?, upper?): return (lower + upper) / 2
        }
    }

    /// The index for a new item appended after `lastIndex`.
    public static func appended(after lastIndex: Double?) -> Double {
        index(after: lastIndex, before: nil)
    }

    /// Moves `offsets` of `items` (already sorted by index) to `destination`, with SwiftUI `onMove` semantics
    /// (`destination` is an offset in the original array). Only the moved items are rewritten, unless the
    /// neighbours ran out of room, in which case the whole list is renumbered.
    ///
    /// - Returns: the items whose index changed, so callers can bump `updatedAt` on exactly those.
    @discardableResult
    public static func move<Item>(
        _ items: [Item],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int,
        index: (Item) -> Double,
        setIndex: (Item, Double) -> Void
    ) -> [Item] {
        let valid = offsets.filter { items.indices.contains($0) }
        guard !valid.isEmpty else { return [] }
        let moving = valid.map { items[$0] }
        let movingSet = Set(valid)
        let remaining = items.indices.filter { !movingSet.contains($0) }.map { items[$0] }
        let clampedDestination = min(max(destination, 0), items.count)
        let insertion = clampedDestination - valid.filter { $0 < clampedDestination }.count

        let lower = insertion > 0 ? index(remaining[insertion - 1]) : nil
        let upper = insertion < remaining.count ? index(remaining[insertion]) : nil

        // Spread the moved block evenly inside the gap.
        let slots = Double(moving.count + 1)
        var assigned: [Double] = []
        switch (lower, upper) {
        case let (lower?, upper?):
            let gap = (upper - lower) / slots
            assigned = (1...moving.count).map { lower + gap * Double($0) }
            if gap < minimumGap { return renumber(remaining, inserting: moving, at: insertion, setIndex: setIndex) }
        case let (lower?, nil):
            assigned = (1...moving.count).map { lower + step * Double($0) }
        case let (nil, upper?):
            assigned = (1...moving.count).map { upper - step * Double(moving.count + 1 - $0) }
        case (nil, nil):
            assigned = (1...moving.count).map { step * Double($0) }
        }
        for (item, value) in zip(moving, assigned) { setIndex(item, value) }
        return moving
    }

    /// Renumbers `remaining` with `moving` spliced in at `insertion`, `step` apart. Returns every item.
    private static func renumber<Item>(_ remaining: [Item], inserting moving: [Item], at insertion: Int, setIndex: (Item, Double) -> Void) -> [Item] {
        var ordered = remaining
        ordered.insert(contentsOf: moving, at: insertion)
        for (position, item) in ordered.enumerated() { setIndex(item, step * Double(position + 1)) }
        return ordered
    }

    /// Places `item` at `position` among `siblings` (sorted, not containing `item`). Used for "move to group" and inserts.
    public static func insert<Item>(
        _ item: Item,
        at position: Int,
        among siblings: [Item],
        index: (Item) -> Double,
        setIndex: (Item, Double) -> Void
    ) {
        let clamped = min(max(position, 0), siblings.count)
        let lower = clamped > 0 ? index(siblings[clamped - 1]) : nil
        let upper = clamped < siblings.count ? index(siblings[clamped]) : nil
        if let lower, let upper, upper - lower < minimumGap * 2 {
            var ordered = siblings
            ordered.insert(item, at: clamped)
            for (offset, element) in ordered.enumerated() { setIndex(element, step * Double(offset + 1)) }
            return
        }
        setIndex(item, self.index(after: lower, before: upper))
    }
}
