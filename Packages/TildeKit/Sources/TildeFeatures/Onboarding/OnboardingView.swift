import SwiftUI
import TildeDesign

/// First launch: the icon, "Tilde. SSH for people who get paged.", and three buttons. Placeholder (WS5).
public struct OnboardingView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: TildeSpacing.l) {
            Text("~").font(TildeFont.mono(72, weight: .bold)).foregroundStyle(TildeColor.accent)
            Text("Tilde. SSH for people who get paged.").font(.title3.weight(.semibold))
        }
        .padding()
    }
}
