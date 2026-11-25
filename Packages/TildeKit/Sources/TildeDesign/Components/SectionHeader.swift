import SwiftUI

/// List section header: caps, 11 pt, +0.6 tracking, `text3`, with an optional mono count and an optional
/// disclosure chevron (for collapsible groups).
public struct SectionHeader: View {
    private let title: String
    private let systemImage: String?
    private let count: Int?
    private let isExpanded: Bool?

    /// - Parameter isExpanded: pass a value to show a disclosure chevron; `nil` for a plain header.
    public init(_ title: String, systemImage: String? = nil, count: Int? = nil, isExpanded: Bool? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.isExpanded = isExpanded
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let isExpanded {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(TildeColor.text3)
                    .accessibilityHidden(true)
            }
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10)).accessibilityHidden(true)
            }
            Text(title).tildeSectionHeader()
            Spacer(minLength: 0)
            if let count {
                Text("\(count)").tildeMono(11, relativeTo: .caption).foregroundStyle(TildeColor.text3)
            }
        }
        .foregroundStyle(TildeColor.text3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded.map { $0 ? "Expanded" : "Collapsed" } ?? "")
    }
}

#Preview("SectionHeader") {
    VStack(spacing: 12) {
        SectionHeader("Favorites", count: 2)
        SectionHeader("Production", systemImage: "bolt.fill", count: 3, isExpanded: true)
        SectionHeader("Homelab", systemImage: "house", count: 1, isExpanded: false)
    }
    .padding().background(TildeColor.bg)
}
