import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Synchronization
import TildeCore

/// Thrown out of the handshake when the pinned key differs from the presented one. The connection is
/// aborted during key exchange, before any credential is sent.
struct HostKeyMismatchError: Error {
    var challenge: HostKeyChallenge
}

/// Thrown when the user (or strict mode, or the 120 s prompt timeout) refused an unknown host key.
struct HostKeyRejectedError: Error, Equatable {}

extension HostKey {
    /// Builds the `HostKey` value for a key presented during key exchange.
    init(_ key: NIOSSHPublicKey) {
        // "algorithm base64-blob": the blob is the standard SSH public key encoding used by known_hosts.
        let line = String(openSSHPublicKey: key)
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let algorithm = parts.first ?? ""
        let blobBase64 = parts.count > 1 ? parts[1] : ""
        self.init(algorithm: algorithm, blobBase64: blobBase64, fingerprintSHA256: Self.fingerprint(ofBlobBase64: blobBase64))
    }

    /// `SHA256:` followed by the unpadded base64 digest of the key blob (what `ssh-keygen -l` prints).
    static func fingerprint(ofBlobBase64 base64: String) -> String {
        guard let blob = Data(base64Encoded: base64) else { return "SHA256:" }
        var encoded = Data(SHA256.hash(data: blob)).base64EncodedString()
        while encoded.hasSuffix("=") { encoded.removeLast() }
        return "SHA256:" + encoded
    }
}

/// Trust-on-first-use host key validation for one endpoint.
///
/// - Pinned and equal: continue.
/// - Unknown: hold the handshake open and ask the `HostKeyPrompter` (strict mode refuses instead).
/// - Different from the pin: fail immediately with `HostKeyMismatchError`. Nothing has been authenticated
///   at this point, so no password or signature reaches the impostor.
///
/// `@unchecked Sendable`: NIOSSH invokes it on the event loop and it only holds immutable `Sendable`
/// references (the prompter is `@MainActor`-isolated and only touched from a `Task`).
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    struct Configuration: Sendable {
        var endpoint: HostEndpoint
        var serverName: String?
        var knownHosts: any KnownHostsStore
        /// `nil` means nobody can be asked, so unknown keys are rejected.
        var prompter: HostKeyAsker?
        var strict: Bool
        var promptTimeout: Duration
        /// Fingerprints the user chose to accept once (the "Connect once" decision on a previous mismatch).
        var allowedOnce: Set<String>
    }

    private let configuration: Configuration
    /// Called when the validator starts or stops waiting for a human, so the connection timeout can pause.
    private let onPrompt: @Sendable (_ waiting: Bool) -> Void
    private let onPresented: @Sendable (HostKey) -> Void

    init(
        _ configuration: Configuration,
        onPresented: @escaping @Sendable (HostKey) -> Void = { _ in },
        onPrompt: @escaping @Sendable (_ waiting: Bool) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.onPresented = onPresented
        self.onPrompt = onPrompt
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = HostKey(hostKey)
        onPresented(presented)
        let configuration = configuration
        let onPrompt = onPrompt
        Task {
            do {
                try await Self.validate(presented, configuration: configuration, onPrompt: onPrompt)
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }

    static func validate(
        _ presented: HostKey,
        configuration c: Configuration,
        onPrompt: @Sendable (Bool) -> Void
    ) async throws {
        let lookup = await c.knownHosts.lookup(c.endpoint, presented: presented)
        switch lookup {
        case .trusted:
            await c.knownHosts.touch(c.endpoint)

        case .unknown:
            if c.allowedOnce.contains(presented.fingerprintSHA256) { return }
            guard !c.strict, let prompter = c.prompter else { throw HostKeyRejectedError() }
            let challenge = HostKeyChallenge(endpoint: c.endpoint, serverName: c.serverName, presented: presented, lookup: lookup)
            onPrompt(true)
            defer { onPrompt(false) }
            let decision = await Self.decide(challenge, prompter: prompter, timeout: c.promptTimeout)
            switch decision {
            case .trustAndSave:
                try await c.knownHosts.trust(presented, for: c.endpoint, replacing: false)
            case .connectOnce:
                break
            case .reject, .none:
                throw HostKeyRejectedError()
            }

        case .mismatch, .conflicted:
            if c.allowedOnce.contains(presented.fingerprintSHA256) { return }
            throw HostKeyMismatchError(
                challenge: HostKeyChallenge(endpoint: c.endpoint, serverName: c.serverName, presented: presented, lookup: lookup)
            )
        }
    }

    /// Asks the prompter, giving up (as a rejection) after `timeout`. The prompter's own task cannot be
    /// cancelled, so the race is done with unstructured tasks and a one-shot continuation.
    private static func decide(_ challenge: HostKeyChallenge, prompter: HostKeyAsker, timeout: Duration) async -> HostKeyDecision? {
        await withCheckedContinuation { (continuation: CheckedContinuation<HostKeyDecision?, Never>) in
            let resumed = Mutex(false)
            let finish: @Sendable (HostKeyDecision?) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: value) }
            }
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                finish(nil)
            }
            Task {
                let decision = await prompter.decide(challenge)
                timer.cancel()
                finish(decision)
            }
        }
    }
}
