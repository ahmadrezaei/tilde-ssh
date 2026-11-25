import SwiftUI

/// Empty state with the mono illustration `~ $ _`, a one-line title, an optional message and action buttons.
public struct EmptyState<Actions: View>: View {
    private let title: String
    private let message: String?
    private let actions: Actions

    public init(_ title: String, message: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: TildeSpacing.l) {
            HStack(spacing: 0) {
                Text("~ $ ").foregroundStyle(TildeColor.text3)
                Text("_").foregroundStyle(TildeColor.accent)
            }
            .tildeMono(34, weight: .semibold, relativeTo: .largeTitle)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(title).tildeText(17, weight: .semibold, relativeTo: .headline).foregroundStyle(TildeColor.text)
                if let message {
                    Text(message).tildeText(14, relativeTo: .subheadline).foregroundStyle(TildeColor.text2)
                        .multilineTextAlignment(.center)
                }
            }
            actions
        }
        .padding(TildeSpacing.xl)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
    }
}

public extension EmptyState where Actions == EmptyView {
    init(_ title: String, message: String? = nil) {
        self.init(title, message: message) { EmptyView() }
    }
}

#Preview("EmptyState") {
    EmptyState("No servers yet.", message: "Add one, or type user@host in the search field.") {
        HStack {
            Button("Add server") {}.buttonStyle(.tildePrimary)
            Button("Quick connect") {}.buttonStyle(.tildeSecondary)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TildeColor.bg)
}
