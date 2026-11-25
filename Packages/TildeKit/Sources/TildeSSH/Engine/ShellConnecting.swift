import Foundation
import TildeCore

/// Everything a connection attempt needs. Built by the engine for each session.
struct ConnectPlan: Sendable {
    var request: SessionRequest
    var credentials: any CredentialResolver
    var knownHosts: any KnownHostsStore
    /// `nil` when nobody can be asked (exec channel): unknown host keys are then rejected.
    var hostKeyPrompter: HostKeyAsker?
    /// `nil` when nobody can be asked: missing or rejected passwords fail the connection.
    var passwordPrompter: PasswordAsker?
    var options: CitadelSessionEngine.Options
    /// Host key fingerprints accepted for this attempt only ("Connect once" after a mismatch).
    var allowedOnceFingerprints: Set<String> = []
}

/// Callbacks a connection attempt uses to report progress.
struct ConnectEvents: Sendable {
    var phase: @Sendable (ConnectPhase) -> Void
    /// Remote bytes for the terminal.
    var output: @Sendable (Data) -> Void
}

/// How a live shell ended.
enum ShellEnd: Sendable, Equatable {
    /// The remote shell exited (or the server closed the channel cleanly).
    case exited(status: Int?)
    /// The connection died underneath us.
    case lost
    /// `close()` was called locally.
    case closedLocally
}

/// A connected, authenticated shell. The seam between the session lifecycle and the network, so the
/// lifecycle (states, keep-alive, backoff) can be tested with a fake.
protocol LiveShell: Sendable {
    var info: ConnectionInfo { get }
    /// Non-blocking, ordered.
    func write(_ data: Data)
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)
    /// One request/response round trip to the server; `nil` if it did not answer within `timeout`.
    func ping(timeout: Duration) async -> Duration?
    /// Returns once the shell has ended, whatever the reason.
    func waitUntilEnded() async -> ShellEnd
    /// Ends the shell locally (`waitUntilEnded` returns `.closedLocally`).
    func close() async
    /// Kills the transport without marking it a local close, so the session treats it as a lost connection
    /// (used when keep-alive replies stop arriving).
    func drop() async
}

protocol ShellConnecting: Sendable {
    /// Resolves credentials, connects (through the jump host if configured), verifies the host key,
    /// authenticates and opens the shell. Throws a `SessionError`, `HostKeyMismatchError` or `ConnectCancelledError`.
    func connect(_ plan: ConnectPlan, size: PTYConfig, events: ConnectEvents) async throws -> any LiveShell
}

/// Sendable handles to the `@MainActor` prompters.
///
/// `@unchecked Sendable`: `HostKeyPrompter` and `PasswordPrompter` are main-actor-isolated protocols, and the
/// wrapped reference is only ever used through `await` (which hops to the main actor), so sharing the
/// reference across tasks is safe even though the existential is not declared `Sendable`.
struct HostKeyAsker: @unchecked Sendable {
    private let prompter: any HostKeyPrompter
    init(_ prompter: any HostKeyPrompter) { self.prompter = prompter }
    func decide(_ challenge: HostKeyChallenge) async -> HostKeyDecision { await prompter.decide(challenge) }
}

struct PasswordAsker: @unchecked Sendable {
    private let prompter: any PasswordPrompter
    init(_ prompter: any PasswordPrompter) { self.prompter = prompter }
    func password(for target: ConnectionTarget, reason: PromptReason) async -> String? {
        await prompter.password(for: target, reason: reason)
    }
}
