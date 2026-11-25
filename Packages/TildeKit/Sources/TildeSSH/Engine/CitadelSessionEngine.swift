import Foundation
import TildeCore

/// The production `SessionEngine`: SSH over swift-nio-ssh (via Citadel's algorithm extensions), with
/// Tilde's own handshake, trust-on-first-use host key checking, RSA SHA-2 client auth, jump host,
/// keep-alive and reconnect.
///
/// Wiring (in `AppEnvironment`):
/// ```swift
/// let engine = CitadelSessionEngine(options: .init(strictHostKeyChecking: prefs.strictHostChecking))
/// ```
public struct CitadelSessionEngine: SessionEngine {
    /// Behaviour switches, mostly mirrored from Settings.
    public struct Options: Sendable {
        /// Refuse unknown host keys instead of asking (Settings › Security › Strict host checking).
        public var strictHostKeyChecking: Bool
        /// How long the handshake waits for the host key sheet (design: 120 s).
        public var hostKeyPromptTimeout: Duration
        /// Automatic reconnect after a dropped connection.
        public var reconnect: ReconnectPolicy
        /// Unanswered keep-alives before the connection is declared dead.
        public var keepAliveMissLimit: Int
        /// After `rsa-sha2-512` and `rsa-sha2-256` fail, also try the SHA-1 `ssh-rsa` signature. Only useful
        /// for servers older than OpenSSH 7.2; SHA-1 signatures are considered broken, so this is off by default.
        public var allowLegacySSHRSA: Bool

        public init(
            strictHostKeyChecking: Bool = false,
            hostKeyPromptTimeout: Duration = .seconds(120),
            reconnect: ReconnectPolicy = .default,
            keepAliveMissLimit: Int = 3,
            allowLegacySSHRSA: Bool = false
        ) {
            self.strictHostKeyChecking = strictHostKeyChecking
            self.hostKeyPromptTimeout = hostKeyPromptTimeout
            self.reconnect = reconnect
            self.keepAliveMissLimit = keepAliveMissLimit
            self.allowLegacySSHRSA = allowLegacySSHRSA
        }
    }

    private let options: Options
    private let connector: any ShellConnecting

    public init(options: Options = Options()) {
        self.init(options: options, connector: NIOShellConnector())
    }

    init(options: Options, connector: any ShellConnecting) {
        self.options = options
        self.connector = connector
    }

    // MARK: SessionEngine

    public func makeSession(
        _ request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore,
        hostKeyPrompter: any HostKeyPrompter,
        passwordPrompter: any PasswordPrompter
    ) -> any TerminalSession {
        CitadelTerminalSession(
            request: request,
            credentials: credentials,
            knownHosts: knownHosts,
            hostKeyPrompter: hostKeyPrompter,
            passwordPrompter: passwordPrompter,
            options: options,
            connector: connector
        )
    }

    public func test(
        _ request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore,
        hostKeyPrompter: any HostKeyPrompter,
        passwordPrompter: any PasswordPrompter
    ) async -> Result<ConnectionInfo, SessionError> {
        let hostAsker = HostKeyAsker(hostKeyPrompter)
        let passwordAsker = PasswordAsker(passwordPrompter)
        let allowedOnce = OnceAllowList()
        var retried = false
        while true {
            let plan = ConnectPlan(
                request: request, credentials: credentials, knownHosts: knownHosts,
                hostKeyPrompter: hostAsker, passwordPrompter: passwordAsker,
                options: options, allowedOnce: allowedOnce
            )
            do {
                let connection = try await ConnectionOpener.open(plan, report: { _ in })
                var info = connection.connectionInfo()
                info.latency = await Self.measureLatency(connection)
                await connection.close()
                return .success(info)
            } catch let mismatch as HostKeyMismatchError {
                // The connection is already aborted. Show the challenge; if the user trusts the new key, try once more.
                let challenge = mismatch.challenge
                guard !retried else { return .failure(.hostKeyMismatch(challengeID: challenge.id)) }
                retried = true
                switch await hostAsker.decide(challenge) {
                case .trustAndSave:
                    guard (try? await knownHosts.trust(challenge.presented, for: challenge.endpoint, replacing: true)) != nil else {
                        return .failure(.underlying("The new host key could not be saved."))
                    }
                case .connectOnce:
                    allowedOnce.insert(challenge.presented, for: challenge.endpoint)
                case .reject:
                    return .failure(.hostKeyMismatch(challengeID: challenge.id))
                }
            } catch is ConnectCancelledError {
                return .failure(.authFailed(method: "password", serverAllows: []))
            } catch {
                return .failure(SessionErrorMapper.map(
                    error, host: request.server.target.host, timeoutSeconds: request.connectTimeout.wholeSecondsRoundedUp
                ))
            }
        }
    }

    public func runCommand(
        _ command: String,
        on request: SessionRequest,
        credentials: any CredentialResolver,
        knownHosts: any KnownHostsStore
    ) async throws -> (stdout: Data, exitStatus: Int) {
        // Nobody can answer prompts here: unknown host keys are rejected and passwords must already be saved.
        let plan = ConnectPlan(
            request: request, credentials: credentials, knownHosts: knownHosts,
            hostKeyPrompter: nil, passwordPrompter: nil, options: options
        )
        let host = request.server.target.host
        let timeoutSeconds = request.connectTimeout.wholeSecondsRoundedUp
        do {
            let connection = try await ConnectionOpener.open(plan, report: { _ in })
            do {
                let result = try await ExecRunner.run(command, on: connection, timeout: .seconds(30))
                await connection.close()
                return result
            } catch {
                await connection.close()
                throw error
            }
        } catch {
            throw SessionErrorMapper.map(error, host: host, timeoutSeconds: timeoutSeconds)
        }
    }

    /// Time to open (and close) a session channel: one protocol round trip.
    private static func measureLatency(_ connection: SSHConnection) async -> Duration? {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let channel = try await SSHSessionChannel.open(on: connection, onOutput: { _, _ in }, onClose: { _ in })
            let elapsed = clock.now - start
            await channel.close()
            return elapsed
        } catch {
            return nil
        }
    }
}
