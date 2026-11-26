import SwiftUI

/// Sizes for the status bar.
public enum StatusBarMetrics {
    public static let height: CGFloat = TildeSpacing.statusBarHeight
}

/// The 24 pt bar under a session (Mac): segments on the left, segments on the right, a hairline on top. It holds
/// no logic; `SessionStatusBar` decides what goes in it.
public struct StatusBar<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: TildeSpacing.xs) { leading }
            Spacer(minLength: TildeSpacing.m)
            HStack(spacing: TildeSpacing.xs) { trailing }
        }
        .padding(.horizontal, TildeSpacing.s)
        .frame(height: StatusBarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(TildeColor.surface, ignoresSafeAreaEdges: [])
        .overlay(alignment: .top) { Rectangle().fill(TildeColor.border).frame(height: TildeSpacing.hairline) }
    }
}

/// One item in the status bar: an optional SF Symbol and a short text. Machine data (addresses, latency, cipher,
/// sizes) is SF Mono 11; labels are SF Pro 11.
public struct StatusBarSegment: View {
    public enum Style: Sendable {
        /// SF Mono 11, for values a machine produced.
        case data
        /// SF Pro 11, for words.
        case label
    }

    private let icon: String?
    private let text: String
    private let style: Style
    private let tint: Color?
    private let help: String?

    public init(icon: String? = nil, _ text: String, style: Style = .data, tint: Color? = nil, help: String? = nil) {
        self.icon = icon
        self.text = text
        self.style = style
        self.tint = tint
        self.help = help
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint ?? TildeColor.text3)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(font)
                .foregroundStyle(tint ?? TildeColor.text2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .help(help ?? text)
        .accessibilityElement(children: .combine)
    }

    private var font: Font {
        switch style {
        case .data: TildeFont.mono(11)
        case .label: .system(size: 11)
        }
    }
}

/// The environment segment: a filled chip with the environment's name (`Production`), so PROD stays obvious. Renders
/// nothing for `.none`.
public struct StatusBarEnvironmentSegment: View {
    private let tone: EnvTone

    public init(_ tone: EnvTone) { self.tone = tone }

    public var body: some View {
        if tone != .none {
            Text(tone.accessibilityName)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(TildeColor.bg)
                .padding(.horizontal, 8)
                .frame(height: 16)
                .background(tone.color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .padding(.trailing, 2)
        }
    }
}

#Preview("StatusBar") {
    StatusBar {
        StatusBarEnvironmentSegment(.prod)
        StatusBarSegment("deploy@10.0.1.12:22")
        StatusBarSegment(icon: "arrow.triangle.turn.up.right.diamond", "via bastion", style: .label)
        StatusBarSegment(icon: "key", "macbook-ed25519")
    } trailing: {
        StatusBarSegment("23 ms", tint: TildeColor.ok)
        StatusBarSegment("chacha20-poly1305")
        StatusBarSegment("126×43")
        StatusBarSegment("UTF-8")
    }
    .frame(width: 720)
    .background(TildeColor.bg)
}
