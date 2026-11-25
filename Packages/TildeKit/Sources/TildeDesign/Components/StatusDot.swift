import SwiftUI

/// 8 pt status dot: reachable / slow / unreachable / unknown, or a pulsing accent for a live session.
public struct StatusDot: View {
    public enum Kind: Sendable, Equatable {
        case ok, slow, unreachable, unknown, live

        /// `ok` under 150 ms, `slow` from 150 ms.
        public init(latencyMilliseconds ms: Int) { self = ms < 150 ? .ok : .slow }

        var color: Color {
            switch self {
            case .ok: TildeColor.ok
            case .slow: TildeColor.warn
            case .unreachable: TildeColor.danger
            case .unknown: TildeColor.text3
            case .live: TildeColor.accent
            }
        }

        var label: String {
            switch self {
            case .ok: "Reachable"
            case .slow: "Slow"
            case .unreachable: "Unreachable"
            case .unknown: "Not checked"
            case .live: "Session open"
            }
        }
    }

    private let kind: Kind
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ kind: Kind) { self.kind = kind }

    public var body: some View {
        Circle()
            .fill(kind.color)
            .frame(width: TildeSpacing.statusDot, height: TildeSpacing.statusDot)
            .shadow(color: kind == .ok || kind == .live ? kind.color.opacity(0.55) : .clear, radius: 3)
            .opacity(kind == .live && pulse ? 0.4 : 1)
            .animation(kind == .live && !reduceMotion ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = (kind == .live && !reduceMotion) }
            .accessibilityLabel(kind.label)
    }
}

/// A status dot with the latency next to it: `● 23ms`. Pass `nil` latency to show just the dot.
public struct LatencyLabel: View {
    private let milliseconds: Int?
    private let kind: StatusDot.Kind

    public init(milliseconds: Int?, kind: StatusDot.Kind? = nil) {
        self.milliseconds = milliseconds
        self.kind = kind ?? milliseconds.map { StatusDot.Kind(latencyMilliseconds: $0) } ?? .unknown
    }

    public var body: some View {
        HStack(spacing: 5) {
            StatusDot(kind)
            if let milliseconds {
                Text("\(milliseconds)ms")
                    .tildeMono(11, weight: .medium, relativeTo: .caption)
                    .foregroundStyle(kind == .slow ? TildeColor.warn : TildeColor.text3)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("StatusDot") {
    VStack(alignment: .leading, spacing: 12) {
        HStack { StatusDot(.ok); StatusDot(.slow); StatusDot(.unreachable); StatusDot(.unknown); StatusDot(.live) }
        HStack(spacing: 16) { LatencyLabel(milliseconds: 23); LatencyLabel(milliseconds: 212); LatencyLabel(milliseconds: nil) }
    }
    .padding().background(TildeColor.bg)
}
