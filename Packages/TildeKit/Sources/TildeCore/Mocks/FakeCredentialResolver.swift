import Foundation

/// A `CredentialResolver` that never touches the Keychain. Returns a fixed password / fake key, or throws
/// `SessionError.secretUnavailable` for the ids listed in `unavailable` (to preview the "waiting for iCloud
/// Keychain" state).
public struct FakeCredentialResolver: CredentialResolver {
    public var password: String
    public var unavailable: Set<SecretRef>

    public init(password: String = "correct horse battery staple", unavailable: Set<SecretRef> = []) {
        self.password = password
        self.unavailable = unavailable
    }

    public func resolve(auth: AuthMethod, keyID: UUID?, passwordSecretID: UUID?, target: ConnectionTarget) async throws -> ResolvedCredential {
        switch auth {
        case .password:
            if let passwordSecretID {
                let ref = SecretRef(kind: .password, id: passwordSecretID)
                if unavailable.contains(ref) { throw SessionError.secretUnavailable(ref) }
            }
            return .password(password)
        case .passwordPrompt:
            return .password(password)
        case .key:
            if let keyID {
                let ref = SecretRef(kind: .privateKey, id: keyID)
                if unavailable.contains(ref) { throw SessionError.secretUnavailable(ref) }
            }
            return .privateKey(PrivateKeyMaterial(algorithm: .ed25519, openSSHBytes: Data("fake-openssh-key".utf8)))
        }
    }
}
