import SwiftUI

/// 8 pt status dot: reachable / slow / unreachable / unknown, or a pulsing accent for a live session.
public struct StatusDot: View {
    public enum Kind: Sendable, Equatable {
        case ok, slow, unreachable, unknown, live
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

    public init(_ kind: Kind) { self.kind = kind }

    public var body: some View {
        Circle()
            .fill(kind.color)
            .frame(width: TildeSpacing.statusDot, height: TildeSpacing.statusDot)
            .opacity(kind == .live && pulse ? 0.35 : 1)
            .animation(kind == .live ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = (kind == .live) }
            .accessibilityLabel(kind.label)
    }
}

#Preview("StatusDot") {
    HStack { StatusDot(.ok); StatusDot(.slow); StatusDot(.unreachable); StatusDot(.unknown); StatusDot(.live) }
        .padding().background(TildeColor.bg)
}
