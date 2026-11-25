import Foundation

/// Fractional ordering for drag-to-reorder (`Server.sortIndex` is a `Double`, because CloudKit has no ordered
/// relationships). Moving one row only rewrites that row, so concurrent edits on two devices rarely collide.
enum FractionalOrder {
    /// A value strictly between the neighbours; open-ended on either side.
    static func value(between lower: Double?, and upper: Double?) -> Double {
        switch (lower, upper) {
        case (nil, nil): 0
        case (let lower?, nil): lower + 1
        case (nil, let upper?): upper - 1
        case (let lower?, let upper?): (lower + upper) / 2
        }
    }

    /// The next free index after the given ones (new rows are appended).
    static func next(after indices: [Double]) -> Double {
        (indices.max() ?? -1) + 1
    }

    /// Applies a SwiftUI `onMove` to rows that are already sorted by index, and returns the new index of every
    /// row that must be rewritten. Falls back to renumbering the whole list when neighbours collide (equal
    /// indices from freshly created rows, or when floating point halving runs out of precision).
    static func move<ID: Hashable>(items: [(id: ID, index: Double)], fromOffsets: IndexSet, toOffset: Int) -> [ID: Double] {
        guard !items.isEmpty, !fromOffsets.isEmpty else { return [:] }
        var order = items.map(\.id)
        let moved = Set(fromOffsets.map { items[$0].id })
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)

        var current = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.index) })
        let hasDuplicates = Set(items.map(\.index)).count != items.count
        var result: [ID: Double] = [:]

        func renumbered() -> [ID: Double] {
            Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, Double($0.offset)) })
        }
        if hasDuplicates { return renumbered() }

        for (position, id) in order.enumerated() where moved.contains(id) {
            let lower = position > 0 ? current[order[position - 1]] : nil
            // The next neighbour that is not itself being moved (its index is still trustworthy).
            let upper = order[(position + 1)...].first { !moved.contains($0) }.flatMap { current[$0] }
            let newIndex = FractionalOrder.value(between: lower, and: upper)
            if let lower, newIndex <= lower { return renumbered() }
            if let upper, newIndex >= upper { return renumbered() }
            current[id] = newIndex
            result[id] = newIndex
        }
        return result
    }
}
