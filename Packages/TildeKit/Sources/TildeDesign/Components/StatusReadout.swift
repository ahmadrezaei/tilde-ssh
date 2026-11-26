import SwiftUI

/// A quiet connection readout for toolbars: a small dot and a short mono value, `● 23 ms`.
///
/// The dot carries the state (green fast, amber slow, red failing, grey unknown, a spinner while connecting); the text
/// stays secondary unless the connection needs attention. There is no capsule or fill, so it sits in a toolbar like a
/// piece of text rather than a button.
public struct StatusReadout: View {
    public enum Quality: Sendable, Equatable {
        case good, slow, bad, idle, busy

        /// `good` under 150 ms, `slow` under 500 ms, `bad` above.
        public init(latencyMilliseconds ms: Int) {
            self = ms < 150 ? .good : (ms < 500 ? .slow : .bad)
        }

        var dotColor: Color {
            switch self {
            case .good: TildeColor.ok
            case .slow: TildeColor.warn
            case .bad: TildeColor.danger
            case .idle: TildeColor.text3
            case .busy: TildeColor.accent
            }
        }

        var textColor: Color {
            switch self {
            case .good, .idle, .busy: TildeColor.text2
            case .slow: TildeColor.warn
            case .bad: TildeColor.danger
            }
        }
    }

    private let quality: Quality
    private let text: String
    private let accessibilityText: String?

    public init(_ quality: Quality, text: String, accessibilityText: String? = nil) {
        self.quality = quality
        self.text = text
        self.accessibilityText = accessibilityText
    }

    public var body: some View {
        HStack(spacing: 6) {
            if quality == .busy {
                ProgressView().controlSize(.mini).tint(quality.dotColor)
            } else {
                Circle()
                    .fill(quality.dotColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: quality == .good ? quality.dotColor.opacity(0.5) : .clear, radius: 2.5)
            }
            Text(text)
                .tildeMono(12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(quality.textColor)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText ?? text)
    }
}

#Preview("StatusReadout") {
    VStack(alignment: .leading, spacing: 12) {
        StatusReadout(.good, text: "23 ms")
        StatusReadout(.slow, text: "212 ms")
        StatusReadout(.bad, text: "Disconnected")
        StatusReadout(.busy, text: "Connecting…")
        StatusReadout(.idle, text: "Connected")
    }
    .padding().background(TildeColor.bg)
}
