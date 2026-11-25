import SwiftUI

public extension View {
    /// Tilde list look: hidden system background, `bg` canvas, `surface` rows with hairline separators.
    func tildeList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(TildeColor.bg)
            .listRowSeparatorTint(TildeColor.border)
    }

    /// Row background for a list row (`surface`), optionally highlighted (selection / live).
    func tildeRowBackground(highlighted: Bool = false) -> some View {
        listRowBackground(highlighted ? TildeColor.accentSoft : TildeColor.surface)
    }

    /// Minimum row height: 44 pt on iOS, 28 pt on Mac.
    func tildeRowHeight() -> some View {
        #if os(macOS)
        frame(minHeight: TildeSpacing.rowHeightMac)
        #else
        frame(minHeight: TildeSpacing.rowHeightTouch)
        #endif
    }
}
