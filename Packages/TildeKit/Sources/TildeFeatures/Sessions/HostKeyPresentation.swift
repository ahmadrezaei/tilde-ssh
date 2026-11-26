import Foundation

/// Where a host-key question is shown.
///
/// - `windowSheet`: the window-modal unknown-host sheet (the only presentation on iPhone and iPad, and on the Mac for
///   questions that belong to no tab, such as "Test connection" in the server editor).
/// - `inTab`: on the Mac, an unknown host asked by a tab is a card over that tab's terminal, so the other tabs keep
///   working while the fingerprint is checked.
/// - `takeover`: a pinned key changed or devices disagree. Always the full-window danger screen.
enum HostKeyPresentation: Equatable {
    case windowSheet, inTab, takeover

    /// - Parameter inTabSupported: `true` where the session screen can host the card (the Mac).
    @MainActor
    static func of(_ request: HostKeyRequest, inTabSupported: Bool = Platform.isMac) -> HostKeyPresentation {
        if request.isChangedKey { return .takeover }
        // A request whose tab is already gone has no `windowID`; it has no screen to show a card on either.
        if inTabSupported, request.tabID != nil, request.windowID != nil { return .inTab }
        return .windowSheet
    }
}

extension SessionCoordinator {
    /// The question the window itself should show (sheet or takeover). In-tab questions are skipped, so one waiting
    /// at the head of the queue never hides a tab-less question or a changed-key takeover behind it. With
    /// `inTabSupported == false` this is exactly `pendingHostKey(in:)`.
    func pendingWindowHostKey(in window: UUID, inTabSupported: Bool = Platform.isMac) -> HostKeyRequest? {
        hostKeyQueue.first { request in
            (request.windowID == nil || request.windowID == window)
                && HostKeyPresentation.of(request, inTabSupported: inTabSupported) != .inTab
        }
    }

    /// The question waiting on this tab, if it is shown in the tab.
    func pendingInTabHostKey(for tabID: UUID, inTabSupported: Bool = Platform.isMac) -> HostKeyRequest? {
        hostKeyQueue.first { $0.tabID == tabID && HostKeyPresentation.of($0, inTabSupported: inTabSupported) == .inTab }
    }
}

/// `1:48` for the time left on a host-key question.
enum HostKeyCountdown {
    static func text(remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
