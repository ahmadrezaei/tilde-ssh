import SwiftUI

/// A destructive button that must be held (default 1.5 s) before it fires, e.g. "Hold to trust new key".
public struct HoldToConfirmButton: View {
    private let title: String
    private let duration: Double
    private let action: () -> Void
    @State private var progress: Double = 0
    @State private var isHolding = false
    @State private var task: Task<Void, Never>?

    public init(_ title: String, duration: Double = 1.5, action: @escaping () -> Void) {
        self.title = title
        self.duration = duration
        self.action = action
    }

    public var body: some View {
        Text(title)
            .tildeText(15, weight: .semibold, relativeTo: .body)
            .foregroundStyle(TildeColor.danger)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(alignment: .leading) {
                GeometryReader { geo in
                    TildeColor.danger.opacity(0.18).frame(width: geo.size.width * progress)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: TildeRadius.card).stroke(TildeColor.danger, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: TildeRadius.card))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isHolding { begin() } }
                .onEnded { _ in cancel() })
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityHint("Press and hold to confirm")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    private func begin() {
        isHolding = true
        task = Task { @MainActor in
            let steps = 30
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(duration / Double(steps)))
                if Task.isCancelled { return }
                progress = Double(step) / Double(steps)
            }
            isHolding = false
            progress = 0
            action()
        }
    }

    private func cancel() {
        task?.cancel()
        isHolding = false
        withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
    }
}

#Preview("HoldToConfirmButton") {
    HoldToConfirmButton("Hold to trust new key") {}.padding().background(TildeColor.bg)
}
