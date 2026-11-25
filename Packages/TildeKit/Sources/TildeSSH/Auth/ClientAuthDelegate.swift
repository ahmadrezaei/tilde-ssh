import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Synchronization
import TildeCore

/// What the server rejected: carried out of the NIOSSH pipeline and mapped to `SessionError.authFailed`.
struct AuthRejectedError: Error, Equatable {
    /// `"password"` or `"publickey"`: what we tried.
    var method: String
    /// Methods the server still accepts (only the ones NIOSSH understands: `publickey`, `password`, `hostbased`).
    /// Empty means the server wants something we cannot do, such as keyboard-interactive.
    var serverAllows: [String]
}

/// The user's secret as the auth delegate needs it.
enum SSHCredential: Sendable {
    case password(String)
    case privateKey(ParsedPrivateKey)

    /// Parses `PrivateKeyMaterial` into signing material.
    static func make(from resolved: ResolvedCredential) throws -> SSHCredential {
        switch resolved {
        case .password(let password):
            return .password(password)
        case .privateKey(let material):
            return .privateKey(try OpenSSHKeyReader.parse(material.openSSHBytes))
        }
    }
}

/// Offers one authentication method after another to the server.
///
/// - Password: offers the password; if the server rejects it, asks `passwordRetry` for a new one
///   (the engine wires that to `PasswordPrompter` with `.rejected`) and offers it on the same connection.
/// - Public key: Ed25519 and ECDSA are a single attempt. RSA tries `rsa-sha2-512`, then `rsa-sha2-256`
///   (NIOSSH does not expose the server's `server-sig-algs`), and only if `allowLegacySSHRSA` is set,
///   finally `ssh-rsa` (SHA-1).
///
/// `@unchecked Sendable`: NIOSSH calls the delegate on the connection's event loop only, and the
/// mutable state is behind a `Mutex` regardless, so the compiler's complaint (a non-Sendable protocol
/// requirement) has no runtime consequence.
final class ClientAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private struct State {
        var calls = 0
        var offeredMethod = ""
        var pendingSchemes: [RSASignatureScheme]
        /// Cleared once authentication succeeded so the secret does not outlive the handshake.
        var credential: SSHCredential?
    }

    private let username: String
    private let passwordRetry: (@Sendable () async -> String?)?
    private let onAttempt: @Sendable () -> Void
    private let state: Mutex<State>

    /// - Parameters:
    ///   - allowLegacySSHRSA: Also try `ssh-rsa` (SHA-1) after the SHA-2 variants. Off by default: every server
    ///     since OpenSSH 7.2 accepts SHA-2, and SHA-1 signatures are broken.
    ///   - passwordRetry: Called after the server rejected a password. `nil` return gives up.
    ///   - onAttempt: Called each time a method is about to be offered (drives `ConnectPhase.authenticating`).
    init(
        username: String,
        credential: SSHCredential,
        allowLegacySSHRSA: Bool = false,
        passwordRetry: (@Sendable () async -> String?)? = nil,
        onAttempt: @escaping @Sendable () -> Void = {}
    ) {
        self.username = username
        self.passwordRetry = passwordRetry
        self.onAttempt = onAttempt
        let schemes: [RSASignatureScheme] = allowLegacySSHRSA ? [.sha512, .sha256, .sha1] : [.sha512, .sha256]
        self.state = Mutex(State(pendingSchemes: schemes, credential: credential))
    }

    /// Drops the secret. Called once authentication has succeeded.
    func forgetCredential() { state.withLock { $0.credential = nil } }

    /// Name of the method the server accepted, e.g. `password`, `ssh-ed25519`, `rsa-sha2-512`.
    var authenticatedWith: String { state.withLock { $0.offeredMethod } }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        onAttempt()
        let (call, credential) = state.withLock { state -> (Int, SSHCredential?) in state.calls += 1; return (state.calls, state.credential) }
        guard let credential else {
            nextChallengePromise.fail(AuthRejectedError(method: "", serverAllows: Self.names(availableMethods)))
            return
        }

        switch credential {
        case .password(let password):
            guard availableMethods.contains(.password) else {
                nextChallengePromise.fail(AuthRejectedError(method: "password", serverAllows: Self.names(availableMethods)))
                return
            }
            if call == 1 {
                offer(password: password, promise: nextChallengePromise)
            } else {
                // The server rejected the previous password.
                guard let passwordRetry else {
                    nextChallengePromise.fail(AuthRejectedError(method: "password", serverAllows: Self.names(availableMethods)))
                    return
                }
                let allows = Self.names(availableMethods)
                Task { [self] in
                    if let retry = await passwordRetry() {
                        offer(password: retry, promise: nextChallengePromise)
                    } else {
                        nextChallengePromise.fail(AuthRejectedError(method: "password", serverAllows: allows))
                    }
                }
            }

        case .privateKey(let key):
            guard availableMethods.contains(.publicKey), let privateKey = nextKey(for: key) else {
                nextChallengePromise.fail(AuthRejectedError(method: "publickey", serverAllows: Self.names(availableMethods)))
                return
            }
            let name = privateKey.publicKey.keyPrefixName
            state.withLock { $0.offeredMethod = name }
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "", offer: .privateKey(.init(privateKey: privateKey))
            ))
        }
    }

    private func offer(password: String, promise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        state.withLock { $0.offeredMethod = "password" }
        promise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .password(.init(password: password))))
    }

    /// The next signing attempt, or `nil` once every variant has been tried.
    private func nextKey(for key: ParsedPrivateKey) -> NIOSSHPrivateKey? {
        switch key {
        case .ed25519(let seed):
            return state.withLock { state in
                guard state.calls == 1 else { return nil }
                return (try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)).map { NIOSSHPrivateKey(ed25519Key: $0) }
            }
        case .ecdsa(let curve, let scalar):
            return state.withLock { state in
                guard state.calls == 1 else { return nil }
                switch curve {
                case .p256: return (try? P256.Signing.PrivateKey(rawRepresentation: scalar)).map { NIOSSHPrivateKey(p256Key: $0) }
                case .p384: return (try? P384.Signing.PrivateKey(rawRepresentation: scalar)).map { NIOSSHPrivateKey(p384Key: $0) }
                case .p521: return (try? P521.Signing.PrivateKey(rawRepresentation: scalar)).map { NIOSSHPrivateKey(p521Key: $0) }
                }
            }
        case .rsa(let components):
            let scheme = state.withLock { state in state.pendingSchemes.isEmpty ? nil : state.pendingSchemes.removeFirst() }
            guard let scheme else { return nil }
            switch scheme {
            case .sha512: return (try? RSAClientPrivateKey<RSASHA512Tag>(components))?.nioKey
            case .sha256: return (try? RSAClientPrivateKey<RSASHA256Tag>(components))?.nioKey
            case .sha1: return (try? RSAClientPrivateKey<RSASHA1Tag>(components))?.nioKey
            }
        }
    }

    static func names(_ methods: NIOSSHAvailableUserAuthenticationMethods) -> [String] {
        var names: [String] = []
        if methods.contains(.publicKey) { names.append("publickey") }
        if methods.contains(.password) { names.append("password") }
        if methods.contains(.hostBased) { names.append("hostbased") }
        return names
    }
}

private extension NIOSSHPublicKey {
    /// The public key algorithm name as written on the wire.
    var keyPrefixName: String { String(openSSHPublicKey: self).split(separator: " ").first.map(String.init) ?? "" }
}
