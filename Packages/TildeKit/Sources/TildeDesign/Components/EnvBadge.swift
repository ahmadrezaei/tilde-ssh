import SwiftUI

/// `PROD` / `STG` / `DEV` / `LAB` capsule. Renders nothing for `.none`.
public struct EnvBadge: View {
    private let tone: EnvTone

    public init(_ tone: EnvTone) { self.tone = tone }

    public var body: some View {
        if tone != .none {
            Text(tone.badgeLabel)
                .tildeMono(10, weight: .bold, relativeTo: .caption2)
                .foregroundStyle(tone.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tone.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(tone.color.opacity(0.35), lineWidth: 1))
                .accessibilityLabel(tone.accessibilityName)
        }
    }
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
        EnvStripe(.prod)
    }
    .padding().background(TildeColor.bg)
}
