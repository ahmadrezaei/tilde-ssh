import Foundation

// MARK: - Credentials resolution

public enum ResolvedCredential: Sendable {
    case password(String)
    case privateKey(PrivateKeyMaterial)
}

public enum PromptReason: Sendable, Equatable {
    case notSaved, rejected, secretNotSynced
}

/// Asks the user for a password (implemented by the session coordinator).
@MainActor public protocol PasswordPrompter: AnyObject {
    func password(for target: ConnectionTarget, reason: PromptReason) async -> String?
}

/// Turns a server's auth settings into usable credentials (reads the Keychain, may throw
/// `SessionError.secretUnavailable`).
public protocol CredentialResolver: Sendable {
    func resolve(auth: AuthMethod, keyID: UUID?, passwordSecretID: UUID?, target: ConnectionTarget) async throws -> ResolvedCredential
}
