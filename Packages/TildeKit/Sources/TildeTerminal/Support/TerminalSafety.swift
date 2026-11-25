import Foundation

/// Rules for text and links that come from the remote side. The remote program is untrusted: a window title
/// can carry control characters or bidi overrides that spoof what the tab says, and a link can point anywhere.
enum TerminalSafety {
    static let maximumTitleLength = 128

    /// The characters a title may not contain: controls, line/paragraph separators and bidi formatting.
    private static func isForbiddenInTitle(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: break
        }
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F,            // Arabic letter mark, LRM, RLM
             0x202A...0x202E,                    // LRE RLE PDF LRO RLO
             0x2066...0x2069:                    // LRI RLI FSI PDI
            return true
        default:
            return false
        }
    }

    /// A window title that is safe to show: control and bidi override characters removed, surrounding space
    /// trimmed, at most 128 characters.
    static func sanitizedTitle(_ title: String) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in title.unicodeScalars where !isForbiddenInTitle(scalar) { cleaned.append(scalar) }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maximumTitleLength else { return trimmed }
        return String(trimmed.prefix(maximumTitleLength))
    }

    /// Schemes a terminal link may open.
    static let allowedLinkSchemes: Set<String> = ["http", "https", "ssh"]

    /// The URL for a link from terminal output (a detected link or OSC 8), or nil when it must not be opened:
    /// other schemes (file, javascript, tel, custom app schemes), relative paths, and links without a host.
    static func openableURL(for link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), allowedLinkSchemes.contains(scheme),
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        return url
    }
}
