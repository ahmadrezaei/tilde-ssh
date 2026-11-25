import SwiftUI

/// Inline banner over a dimmed terminal: a headline, an optional monospaced detail line, and up to three actions.
public struct Banner: View {
    public enum Kind: Sendable {
        case info, warning, error
        var color: Color {
            switch self {
            case .info: TildeColor.info
            case .warning: TildeColor.warn
            case .error: TildeColor.danger
            }
        }
    }

    public struct Action: Identifiable {
        public let id = UUID()
        public let title: String
        public let handler: () -> Void
        public init(_ title: String, handler: @escaping () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    private let kind: Kind
    private let headline: String
    private let detail: String?
    private let actions: [Action]

    public init(_ kind: Kind, headline: String, detail: String? = nil, actions: [Action] = []) {
        self.kind = kind
        self.headline = headline
        self.detail = detail
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TildeSpacing.s) {
            Text(headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(TildeColor.text)
            if let detail {
                Text(detail).font(TildeFont.rowSubtitle).foregroundStyle(TildeColor.text2)
            }
            if !actions.isEmpty {
                HStack(spacing: TildeSpacing.s) {
                    ForEach(actions) { action in
                        Button(action.title, action: action.handler).buttonStyle(.bordered).tint(kind.color)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(TildeSpacing.m)
        .background(TildeColor.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: TildeRadius.card))
        .overlay(alignment: .leading) { Rectangle().fill(kind.color).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: TildeRadius.card))
        .accessibilityElement(children: .contain)
    }
}

#Preview("Banner") {
    Banner(.error, headline: "Connection refused · 10.0.1.12:22", detail: "sshd not running or wrong port.",
           actions: [.init("Retry") {}, .init("Edit") {}])
        .padding().background(TildeColor.bg)
}
