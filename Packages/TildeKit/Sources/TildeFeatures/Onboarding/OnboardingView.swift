import SwiftUI
import TildeDesign

/// First launch (design section 4.8): the icon, "Tilde. SSH for people who get paged.", three buttons, one line of
/// reassurance. No carousel.
public struct OnboardingView: View {
    private let onAddServer: () -> Void
    private let onImport: () -> Void
    private let onGenerateKey: () -> Void
    private let onSkip: () -> Void
    private let iCloudAvailable: Bool
    private let onOpenSettings: () -> Void

    /// Height of the visible area (inside the safe area), so the content can centre itself when it fits and scroll when it doesn't.
    @State private var viewportHeight: CGFloat = 0

    /// Small phones get a smaller logo and tighter spacing so most of the content is on screen without scrolling.
    private var isCompact: Bool { viewportHeight > 0 && viewportHeight < 560 }

    /// - Parameters:
    ///   - iCloudAvailable: pass `false` to show "Servers are stored on this device. Turn on iCloud sync in Settings." (from the sync status monitor).
    public init(
        iCloudAvailable: Bool = true,
        onAddServer: @escaping () -> Void = {},
        onImport: @escaping () -> Void = {},
        onGenerateKey: @escaping () -> Void = {},
        onSkip: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.iCloudAvailable = iCloudAvailable
        self.onAddServer = onAddServer
        self.onImport = onImport
        self.onGenerateKey = onGenerateKey
        self.onSkip = onSkip
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: isCompact ? TildeSpacing.l : TildeSpacing.xl) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("~").tildeMono(isCompact ? 56 : 84, weight: .heavy, relativeTo: .largeTitle).foregroundStyle(TildeColor.accent)
                    RoundedRectangle(cornerRadius: 3).fill(TildeColor.accent)
                        .frame(width: isCompact ? 17 : 26, height: isCompact ? 36 : 54)
                }
                .accessibilityHidden(true)

                Text("Tilde. SSH for people who get paged.")
                    .tildeText(22, weight: .bold, relativeTo: .title2)
                    .foregroundStyle(TildeColor.text)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                if !iCloudAvailable {
                    Banner(.info, headline: "iCloud sync is off",
                           detail: "Servers are stored on this device. Turn on iCloud sync in Settings.",
                           actions: [.init("Settings", handler: onOpenSettings)])
                }

                VStack(spacing: TildeSpacing.s) {
                    Button("Add a server", action: onAddServer).buttonStyle(.tildePrimary)
                    Button(importTitle, action: onImport).buttonStyle(.tildeSecondary)
                    Button("Generate an SSH key", action: onGenerateKey).buttonStyle(.tildeSecondary)
                }

                if iCloudAvailable {
                    Text("Servers sync with iCloud. Secrets stay in iCloud Keychain.")
                        .tildeText(13, relativeTo: .footnote)
                        .foregroundStyle(TildeColor.text3)
                        .multilineTextAlignment(.center)
                }

                Button("Skip", action: onSkip).buttonStyle(.plain).tildeText(13, weight: .semibold, relativeTo: .footnote).foregroundStyle(TildeColor.text2)
            }
            .padding(TildeSpacing.xl)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, minHeight: viewportHeight)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(0, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom)
        } action: { viewportHeight = $0 }
    }

    private var importTitle: String { Platform.isMac ? "Import ~/.ssh/config" : "Import from Files" }
}

#Preview("Onboarding") {
    OnboardingView().background(TildeColor.bg).preferredColorScheme(.dark)
}

#Preview("Onboarding: iCloud off") {
    OnboardingView(iCloudAvailable: false).background(TildeColor.bg).preferredColorScheme(.dark)
}
