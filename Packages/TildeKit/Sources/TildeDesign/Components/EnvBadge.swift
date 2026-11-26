import SwiftUI

/// `PROD` / `STG` / `DEV` / `LAB` capsule. Renders nothing for `.none`.
public struct EnvBadge: View {
    /// `regular` is the list and detail badge; `compact` is the smaller one for Mac sidebar rows and tabs.
    public enum Size: Sendable { case regular, compact }

    private let tone: EnvTone
    private let size: Size

    public init(_ tone: EnvTone, size: Size = .regular) {
        self.tone = tone
        self.size = size
    }

    public var body: some View {
        if tone != .none {
            label
                .foregroundStyle(tone.color)
                .padding(.horizontal, size == .compact ? 4 : 6)
                .padding(.vertical, size == .compact ? 1 : 2)
                .background(tone.color.opacity(0.14), in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).stroke(tone.color.opacity(0.35), lineWidth: size == .compact ? TildeSpacing.hairline : 1))
                .accessibilityLabel(tone.accessibilityName)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch size {
        case .regular: Text(tone.badgeLabel).tildeMono(10, weight: .bold, relativeTo: .caption2)
        case .compact: Text(tone.badgeLabel).font(TildeFont.badgeCompact)
        }
    }

    private var radius: CGFloat { size == .compact ? TildeRadius.badge : 5 }
}

/// The 2 pt environment stripe on the top edge of tabs and the terminal title bar. Clear for `.none`.
public struct EnvStripe: View {
    private let tone: EnvTone

    public init(_ tone: EnvTone) { self.tone = tone }

    public var body: some View {
        Rectangle()
            .fill(tone == .none ? Color.clear : tone.color)
            .frame(height: TildeSpacing.envStripe)
            .accessibilityHidden(true)
    }
}

#Preview("EnvBadge") {
    VStack(spacing: 12) {
        HStack { ForEach(EnvTone.allCases, id: \.self) { EnvBadge($0) } }
        HStack { ForEach(EnvTone.allCases, id: \.self) { EnvBadge($0, size: .compact) } }
        EnvStripe(.prod)
    }
    .padding().background(TildeColor.bg)
}
