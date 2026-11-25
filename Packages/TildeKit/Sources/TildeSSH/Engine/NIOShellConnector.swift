import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Synchronization
import TildeCore

/// Opens SSH connections (optionally through a jump host) and shells or exec channels on them.
enum ConnectionOpener {
    /// Resolves credentials, opens the bastion (if any) and then the target, authenticated.
    static func open(_ plan: ConnectPlan, report: @escaping @Sendable (ConnectPhase) -> Void) async throws -> SSHConnection {
        let server = plan.request.server
        let timeout = plan.request.connectTimeout

        var jumpConnection: SSHConnection?
        if let jump = server.jump {
            let credential = try await resolveCredential(
                auth: jump.auth, keyID: jump.keyID, secretID: jump.passwordSecretID, target: jump.target, plan: plan
            )
            let hop = HopParameters(
                endpoint: HostEndpoint(host: jump.target.host, port: jump.target.port),
                username: jump.target.username,
                credential: credential.credential,
                allowLegacySSHRSA: plan.options.allowLegacySSHRSA,
                passwordRetry: credential.retry,
                hostKey: hostKeyConfiguration(for: HostEndpoint(host: jump.target.host, port: jump.target.port), name: "Jump host \(jump.target.host)", plan: plan),
                timeout: timeout,
                // Everything about the bastion reads as "jump host" except the host key prompt.
                report: { phase in report(phase == .hostKey ? .hostKey : .jumpHost) }
            )
            report(.jumpHost)
            jumpConnection = try await SSHConnector.open(hop)
        }

        do {
            let credential = try await resolveCredential(
                auth: server.auth, keyID: server.keyID, secretID: server.passwordSecretID, target: server.target, plan: plan
            )
            let endpoint = HostEndpoint(host: server.target.host, port: server.target.port)
            let hop = HopParameters(
                endpoint: endpoint,
                username: server.target.username,
                credential: credential.credential,
                allowLegacySSHRSA: plan.options.allowLegacySSHRSA,
                passwordRetry: credential.retry,
                hostKey: hostKeyConfiguration(for: endpoint, name: server.name, plan: plan),
                timeout: timeout,
                report: report
            )
            return try await SSHConnector.open(hop, through: jumpConnection)
        } catch {
            if let jumpConnection { await jumpConnection.close() }
            throw error
        }
    }

    private static func hostKeyConfiguration(for endpoint: HostEndpoint, name: String?, plan: ConnectPlan) -> TOFUHostKeyValidator.Configuration {
        TOFUHostKeyValidator.Configuration(
            endpoint: endpoint,
            serverName: name,
            knownHosts: plan.knownHosts,
            prompter: plan.hostKeyPrompter,
            strict: plan.options.strictHostKeyChecking,
            promptTimeout: plan.options.hostKeyPromptTimeout,
            allowedOnce: plan.allowedOnce
        )
    }

    // MARK: Credentials

    private struct Resolved {
        var credential: SSHCredential
        var retry: (@Sendable () async -> String?)?
    }

    /// Turns the server's auth settings into a credential, prompting for passwords when needed.
    private static func resolveCredential(
        auth: AuthMethod, keyID: UUID?, secretID: UUID?, target: ConnectionTarget, plan: ConnectPlan
    ) async throws -> Resolved {
        let prompter = plan.passwordPrompter
        let retry: (@Sendable () async -> String?)? = prompter.map { prompter in
            { @Sendable in await prompter.password(for: target, reason: .rejected) }
        }

        switch auth {
        case .passwordPrompt:
            guard let prompter else { throw SessionError.authFailed(method: "password", serverAllows: []) }
            guard let password = await prompter.password(for: target, reason: .notSaved) else { throw ConnectCancelledError() }
            return Resolved(credential: .password(password), retry: retry)

        case .password:
            do {
                let resolved = try await plan.credentials.resolve(auth: auth, keyID: keyID, passwordSecretID: secretID, target: target)
                return Resolved(credential: try SSHCredential.make(from: resolved), retry: retry)
            } catch let error as SessionError {
                guard case .secretUnavailable = error, let prompter else { throw error }
                guard let password = await prompter.password(for: target, reason: .secretNotSynced) else { throw error }
                return Resolved(credential: .password(password), retry: retry)
            }

        case .key:
            let resolved = try await plan.credentials.resolve(auth: auth, keyID: keyID, passwordSecretID: secretID, target: target)
            do {
                return Resolved(credential: try SSHCredential.make(from: resolved), retry: nil)
            } catch let error as OpenSSHKeyError {
                // Never include key bytes in the message.
                switch error {
                case .encrypted: throw SessionError.underlying("The private key is passphrase-protected; import it again with its passphrase.")
                case .unsupportedAlgorithm(let name): throw SessionError.underlying("Unsupported key type \(name).")
                default: throw SessionError.underlying("The private key could not be read.")
                }
            }
        }
    }
}

/// The production `ShellConnecting`: real sockets, NIOSSH.
struct NIOShellConnector: ShellConnecting {
    func connect(_ plan: ConnectPlan, size: PTYConfig, events: ConnectEvents) async throws -> any LiveShell {
        let connection = try await ConnectionOpener.open(plan, report: events.phase)
        events.phase(.openingShell)
        do {
            return try await NIOLiveShell.open(on: connection, plan: plan, size: size, events: events)
        } catch {
            await connection.close()
            throw error
        }
    }
}

/// A shell channel with a PTY on an authenticated connection.
final class NIOLiveShell: LiveShell {
    let info: ConnectionInfo
    private let connection: SSHConnection
    private let channel: SSHSessionChannel
    private let ended: EventLoopFuture<ShellEnd>
    private let closedLocally = Mutex(false)

    private init(info: ConnectionInfo, connection: SSHConnection, channel: SSHSessionChannel, ended: EventLoopFuture<ShellEnd>) {
        self.info = info
        self.connection = connection
        self.channel = channel
        self.ended = ended
    }

    static func open(on connection: SSHConnection, plan: ConnectPlan, size: PTYConfig, events: ConnectEvents) async throws -> NIOLiveShell {
        let loop = connection.channel.eventLoop
        let endPromise = loop.makePromise(of: ShellEnd.self)
        let server = plan.request.server

        let channel: SSHSessionChannel
        do {
            channel = try await SSHSessionChannel.open(
            on: connection,
            onOutput: { data, _ in events.output(data) },
            onClose: { close in
                // Decide between "the shell exited" and "the connection died".
                if close.exitStatus != nil {
                    endPromise.succeed(.exited(status: close.exitStatus))
                } else if close.exitSignal != nil {
                    endPromise.succeed(.exited(status: nil))
                } else if !connection.isActive || close.error != nil {
                    endPromise.succeed(.lost)
                } else {
                    endPromise.succeed(.exited(status: nil))
                }
            }
            )
        } catch {
            // NIO insists every promise is completed.
            endPromise.fail(error)
            throw error
        }

        // Environment first (most servers refuse it; that is fine), then terminal, then shell.
        let environment = server.envVars.merging(size.env) { _, new in new }
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            try await channel.request(SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: name, value: value), wantReply: false)
        }

        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: size.term,
            terminalCharacterWidth: size.cols,
            terminalRowHeight: size.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            // UTF-8 line discipline (IUTF8) so erase works on multi-byte characters.
            terminalModes: SSHTerminalModes([.ECHO: 1, SSHTerminalModes.Opcode(rawValue: 42): 1])
        )
        guard try await channel.request(pty, wantReply: true) else {
            await channel.close()
            throw SessionError.channelFailed("The server refused to allocate a terminal.")
        }
        guard try await channel.request(SSHChannelRequestEvent.ShellRequest(wantReply: true), wantReply: true) else {
            await channel.close()
            throw SessionError.channelFailed("The server refused to start a shell.")
        }

        for line in StartupScript.lines(for: server) {
            channel.write(Data((line + "\n").utf8))
        }

        return NIOLiveShell(info: connection.connectionInfo(), connection: connection, channel: channel, ended: endPromise.futureResult)
    }

    func write(_ data: Data) { channel.write(data) }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        channel.windowChange(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    func setReading(_ enabled: Bool) { channel.setReading(enabled) }

    func ping(timeout: Duration) async -> Duration? {
        guard connection.isActive else { return nil }
        let clock = ContinuousClock()
        let start = clock.now
        // An `env` request with want-reply, sent after the shell has started, always draws a reply
        // (FAILURE on OpenSSH) without any side effect: a portable stand-in for `keepalive@openssh.com`.
        let channel = self.channel
        let request = SSHChannelRequestEvent.EnvironmentRequest(wantReply: true, name: "TILDE_KEEPALIVE", value: "1")
        do {
            _ = try await withLoopTimeout(loop: connection.channel.eventLoop, timeout: timeout) {
                try await channel.request(request, wantReply: true)
            }
            return clock.now - start
        } catch {
            return nil
        }
    }

    func waitUntilEnded() async -> ShellEnd {
        let end = (try? await ended.get()) ?? .lost
        return closedLocally.withLock { $0 } ? .closedLocally : end
    }

    func close() async {
        closedLocally.withLock { $0 = true }
        await channel.close()
        await connection.close()
    }

    func drop() async {
        await connection.close()
    }
}

struct LoopTimeoutError: Error {}

/// Runs `operation`, throwing `LoopTimeoutError` if it takes longer than `timeout`. The losing side is
/// abandoned rather than cancelled, because NIO futures cannot be cancelled.
func withLoopTimeout<T: Sendable>(
    loop: any EventLoop, timeout: Duration, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let promise = loop.makePromise(of: T.self)
    let timer = loop.scheduleTask(in: timeout.timeAmount) {
        promise.fail(LoopTimeoutError())
    }
    Task {
        do { promise.succeed(try await operation()) } catch { promise.fail(error) }
    }
    defer { timer.cancel() }
    return try await promise.futureResult.get()
}
