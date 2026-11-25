import Foundation

public extension SecretRef {
    /// The nil UUID. A `SecretRef` carrying it is never a real Keychain item: the credential resolver uses it in
    /// `SessionError.secretUnavailable` to say "nothing was saved" (no password saved for the server, or no key
    /// assigned) as opposed to "saved, but not on this device yet". The Keychain store refuses to write it.
    static let sentinelID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// `true` for the "nothing was saved" sentinel refs (see `sentinelID`). Check this before asking the user for a
    /// password with `PromptReason.notSaved` versus `.secretNotSynced`.
    var isUnsavedSentinel: Bool { id == Self.sentinelID }
}
