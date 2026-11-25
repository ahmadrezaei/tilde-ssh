import SwiftUI

/// A filter chip: `k8s`, `db`, `edge`. Accent-tinted when on.
public struct TagChip: View {
    private let title: String
    private let isOn: Bool
    private let action: () -> Void

    public init(_ title: String, isOn: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .tildeMono(11, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(isOn ? TildeColor.accent : TildeColor.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isOn ? TildeColor.accentSoft : TildeColor.surface2, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isOn ? TildeColor.accent.opacity(0.45) : TildeColor.border, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("TagChip") {
    HStack { TagChip("All", isOn: true) {}; TagChip("k8s", isOn: false) {}; TagChip("db", isOn: false) {} }
        .padding().background(TildeColor.bg)
}
