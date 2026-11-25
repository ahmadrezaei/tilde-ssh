import Foundation
import NIOCore

extension Duration {
    /// The duration in seconds, keeping the fractional part.
    var totalSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }

    /// Whole seconds rounded up (at least 1), for error values such as `SessionError.timeout(seconds:)`.
    var wholeSecondsRoundedUp: Int { max(1, Int(totalSeconds.rounded(.up))) }

    var timeAmount: TimeAmount { .nanoseconds(Int64((totalSeconds * 1_000_000_000).rounded())) }
}
