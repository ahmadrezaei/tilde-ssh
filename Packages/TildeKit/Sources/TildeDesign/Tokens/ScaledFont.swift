import SwiftUI

/// Monospaced text that follows Dynamic Type. `Font.system(size:)` alone does not scale, so the size goes
/// through `@ScaledMetric`, relative to a text style.
public struct TildeMonoModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    public init(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) {
        self._size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    public func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: .monospaced))
    }
}

/// Chrome text at a fixed design size that still follows Dynamic Type.
public struct TildeScaledFontModifier: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight

    public init(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) {
        self._size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    public func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight))
    }
}

public extension View {
    /// SF Mono at `size` pt (at the default Dynamic Type setting), scaling with the user's text size.
    func tildeMono(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(TildeMonoModifier(size: size, weight: weight, relativeTo: style))
    }

    /// SF Pro at `size` pt (at the default Dynamic Type setting), scaling with the user's text size.
    func tildeText(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(TildeScaledFontModifier(size: size, weight: weight, relativeTo: style))
    }
}
