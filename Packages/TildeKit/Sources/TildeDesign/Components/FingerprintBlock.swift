import SwiftUI

/// A labelled fingerprint row: `ED25519  SHA256:p3Kc9y...`, with an optional caption (`first trusted 2026-03-14`).
/// Text is selectable and reads as one VoiceOver element.
public struct FingerprintRow: View {
    private let label: String
    private let algorithm: String
    private let fingerprint: String
    private let caption: String?
    private let tint: Color

    public init(label: String, algorithm: String, fingerprint: String, caption: String? = nil, tint: Color = TildeColor.text2) {
        self.label = label
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.caption = caption
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label.uppercased()).tildeMono(10, weight: .bold, relativeTo: .caption2).tracking(0.8).foregroundStyle(tint)
                Spacer()
                Text(algorithm).tildeMono(10, weight: .semibold, relativeTo: .caption2).foregroundStyle(TildeColor.text2)
            }
            Text(fingerprint)
                .tildeMono(12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(TildeColor.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let caption {
                Text(caption).tildeMono(10, relativeTo: .caption2).foregroundStyle(TildeColor.text3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(algorithm), \(fingerprint)")
    }
}

/// A rounded container for one or more `FingerprintRow`s.
public struct FingerprintBlock<Content: View>: View {
    private let tint: Color
    private let content: Content

    public init(tint: Color = TildeColor.border, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) { content }
            .background(TildeColor.bg.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint, lineWidth: 1))
    }
}

#Preview("FingerprintBlock") {
    FingerprintBlock(tint: TildeColor.danger.opacity(0.4)) {
        FingerprintRow(label: "Expected", algorithm: "ED25519", fingerprint: "SHA256:4f+HqTn1dQrZ0vAbCdEfGhIjKlMnOpQrStUvWx0Vw0",
                       caption: "first trusted 2026-03-14 on MacBook-Pro", tint: TildeColor.ok)
        Divider()
        FingerprintRow(label: "Received", algorithm: "ED25519", fingerprint: "SHA256:Zk81Lr0aP2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxmQ9", tint: TildeColor.danger)
    }
    .padding().background(TildeColor.bg)
}
