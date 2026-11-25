import Foundation

/// A `HostKeyPrompter` that answers immediately. Defaults to trusting; set `decision` to `.reject` etc.
/// `challenges` records what was asked.
@MainActor public final class AlwaysTrustPrompter: HostKeyPrompter {
    public var decision: HostKeyDecision
    public private(set) var challenges: [HostKeyChallenge] = []

    public init(decision: HostKeyDecision = .trustAndSave) { self.decision = decision }

    public func decide(_ challenge: HostKeyChallenge) async -> HostKeyDecision {
        challenges.append(challenge)
        return decision
    }
}

/// A `PasswordPrompter` that returns a fixed password (or `nil` to simulate the user cancelling).
@MainActor public final class FakePasswordPrompter: PasswordPrompter {
    public var response: String?
    public private(set) var requests: [(target: ConnectionTarget, reason: PromptReason)] = []

    public init(response: String? = "correct horse battery staple") { self.response = response }

    public func password(for target: ConnectionTarget, reason: PromptReason) async -> String? {
        requests.append((target, reason))
        return response
    }
}
