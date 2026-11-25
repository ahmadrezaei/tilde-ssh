import SwiftUI

/// `PROD` / `STG` / `DEV` / `LAB` capsule. Renders nothing for `.none`.
public struct EnvBadge: View {
    private let tone: EnvTone

    public init(_ tone: EnvTone) { self.tone = tone }

    public var body: some View {
        if tone != .none {
            Text(tone.badgeLabel)
                .font(TildeFont.badge)
                .foregroundStyle(tone.color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tone.color.opacity(0.16), in: Capsule())
                .accessibilityLabel(tone.accessibilityName)
        }
    }
}

#Preview("EnvBadge") {
    HStack { ForEach(EnvTone.allCases, id: \.self) { EnvBadge($0) } }
        .padding().background(TildeColor.bg)
}
