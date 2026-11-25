import Foundation
import TildeCore

/// Turns a server's authentication settings into usable credentials by reading the Keychain.
///
/// Behaviour contract for the session engine (WS2):
/// - `.password` with a stored secret returns `.password`.
/// - A secret that is **not on this device (yet)** throws `SessionError.secretUnavailable(ref)`. For a password
///   ref the engine should ask the user (`PromptReason.secretNotSynced`); for a key ref it shows "waiting for
///   iCloud Keychain".
/// - `.passwordPrompt`, and `.password` without a `passwordSecretID` (nothing was saved), throw
///   `secretUnavailable(DefaultCredentialResolver.unsavedPasswordRef)`, a sentinel whose id is the nil UUID.
///   The engine should ask the user (`PromptReason.notSaved`) and never call the resolver for that again.
/// - `.key` returns the unencrypted `openssh-key-v1` bytes. A key stored passphrase-protected (v1.1 "keep
///   encrypted" mode) is unlocked with its `kpp:<uuid>` secret.
///
/// `keyID` is the key's `SSHKeyRecord.privateSecretID` (the id of the `key:<uuid>` Keychain item).
public struct DefaultCredentialResolver: CredentialResolver {
    /// Sentinel ref meaning "no password was ever saved for this server".
    public static let unsavedPasswordRef = SecretRef(kind: .password, id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
    /// Sentinel ref meaning "the server has no key assigned".
    public static let unassignedKeyRef = SecretRef(kind: .privateKey, id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))

    private let secrets: any SecretStore

    public init(secretStore: any SecretStore) {
        self.secrets = secretStore
    }

    public func resolve(auth: AuthMethod, keyID: UUID?, passwordSecretID: UUID?, target: ConnectionTarget) async throws -> ResolvedCredential {
        switch auth {
        case .passwordPrompt:
            throw SessionError.secretUnavailable(Self.unsavedPasswordRef)
        case .password:
            guard let passwordSecretID else { throw SessionError.secretUnavailable(Self.unsavedPasswordRef) }
            let ref = SecretRef(kind: .password, id: passwordSecretID)
            guard var data = try readSecret(ref) else { throw SessionError.secretUnavailable(ref) }
            defer { data.resetBytes(in: 0..<data.count) }
            guard let password = String(data: data, encoding: .utf8) else {
                throw SessionError.underlying("The saved password could not be read.")
            }
            return .password(password)
        case .key:
            guard let keyID else { throw SessionError.secretUnavailable(Self.unassignedKeyRef) }
            let ref = SecretRef(kind: .privateKey, id: keyID)
            guard var data = try readSecret(ref) else { throw SessionError.secretUnavailable(ref) }
            defer { data.resetBytes(in: 0..<data.count) }
            return .privateKey(try material(from: data, keyID: keyID))
        }
    }

    /// Reads a secret, turning Keychain failures into a `SessionError` that carries no secret data.
    private func readSecret(_ ref: SecretRef) throws -> Data? {
        do {
            return try secrets.read(ref)
        } catch {
            throw SessionError.underlying("The Keychain could not be read.")
        }
    }

    private func material(from stored: Data, keyID: UUID) throws -> PrivateKeyMaterial {
        do {
            let key = try OpenSSHPrivateKeyCodec.decode(stored, passphrase: nil)
            return PrivateKeyMaterial(algorithm: key.algorithm, openSSHBytes: stored)
        } catch KeyParseError.passphraseRequired {
            // Key stored encrypted: its passphrase lives in `kpp:<uuid>`.
            let ref = SecretRef(kind: .keyPassphrase, id: keyID)
            guard var passphraseData = try readSecret(ref) else { throw SessionError.secretUnavailable(ref) }
            defer { passphraseData.resetBytes(in: 0..<passphraseData.count) }
            let passphrase = String(data: passphraseData, encoding: .utf8)
            do {
                let key = try OpenSSHPrivateKeyCodec.decode(stored, passphrase: passphrase)
                return PrivateKeyMaterial(algorithm: key.algorithm, openSSHBytes: try OpenSSHPrivateKeyCodec.encode(key))
            } catch {
                throw SessionError.underlying("The saved key could not be unlocked.")
            }
        } catch {
            throw SessionError.underlying("The saved key could not be read.")
        }
    }
}
