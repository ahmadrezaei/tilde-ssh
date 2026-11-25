import SwiftUI

/// Filled mint button (primary action): "Trust & Connect", "Save & Connect", "Connect".
public struct TildePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tildeText(15, weight: .bold, relativeTo: .body)
            .foregroundStyle(Color(hex: 0x04201C))
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(configuration.isPressed ? TildeColor.accentStrong : TildeColor.accent, in: RoundedRectangle(cornerRadius: 14))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Outlined neutral button (secondary action).
public struct TildeSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tildeText(14, weight: .semibold, relativeTo: .body)
            .foregroundStyle(TildeColor.text)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(configuration.isPressed ? TildeColor.surface3 : TildeColor.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(TildeColor.border, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Solid light button used for the safe choice on danger screens ("Disconnect").
public struct TildeInvertedButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tildeText(15, weight: .heavy, relativeTo: .body)
            .foregroundStyle(Color(hex: 0x0B0F14))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color(hex: 0xE6EDF3).opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

public extension ButtonStyle where Self == TildePrimaryButtonStyle {
    static var tildePrimary: TildePrimaryButtonStyle { TildePrimaryButtonStyle() }
}

public extension ButtonStyle where Self == TildeSecondaryButtonStyle {
    static var tildeSecondary: TildeSecondaryButtonStyle { TildeSecondaryButtonStyle() }
}

public extension ButtonStyle where Self == TildeInvertedButtonStyle {
    static var tildeInverted: TildeInvertedButtonStyle { TildeInvertedButtonStyle() }
}

#Preview("Buttons") {
    VStack(spacing: 10) {
        Button("Trust & Connect") {}.buttonStyle(.tildePrimary)
        Button("Connect Once") {}.buttonStyle(.tildeSecondary)
        Button("Disconnect") {}.buttonStyle(.tildeInverted)
        Button("Disabled") {}.buttonStyle(.tildePrimary).disabled(true)
    }
    .padding().background(TildeColor.bg)
}
