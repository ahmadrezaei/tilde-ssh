import Citadel
import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Synchronization
import TildeCore

/// One authenticated SSH transport: a TCP connection, or a `direct-tcpip` channel through a jump host.
/// Session and exec channels are opened on it.
final class SSHConnection: Sendable {
    /// The TCP channel (or the forwarded child channel for the second hop).
    let channel: Channel
    /// Present when this connection runs through a bastion; closing this closes the bastion too.
    let jumpHost: SSHConnection?
    let hello: ServerHelloBox
    let authDelegate: ClientAuthDelegate
    private let sshHandler: NIOLoopBoundBox<NIOSSHHandler>
    private let clientKexNames: [String]
    private let clientCipherNames: [String]

    fileprivate init(
        channel: Channel, sshHandler: NIOLoopBoundBox<NIOSSHHandler>, jumpHost: SSHConnection?, hello: ServerHelloBox,
        authDelegate: ClientAuthDelegate, clientKexNames: [String], clientCipherNames: [String]
    ) {
        self.channel = channel
        self.sshHandler = sshHandler
        self.jumpHost = jumpHost
        self.hello = hello
        self.authDelegate = authDelegate
        self.clientKexNames = clientKexNames
        self.clientCipherNames = clientCipherNames
    }

    var isActive: Bool { channel.isActive }

    /// Completes when the transport closes (for any reason).
    var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

    /// What was negotiated, derived from the server's KEXINIT and our own preference order.
    func connectionInfo() -> ConnectionInfo {
        let hello = hello.value
        let kex = hello.kexInit.flatMap { AlgorithmNegotiation.choose(client: clientKexNames, server: $0.kexAlgorithms) }
        let cipher = hello.kexInit.flatMap { AlgorithmNegotiation.choose(client: clientCipherNames, server: $0.ciphersClientToServer) }
        return ConnectionInfo(
            serverVersion: hello.banner ?? "unknown",
            kex: kex ?? "unknown",
            cipher: cipher ?? "unknown",
            authenticatedWith: authDelegate.authenticatedWith
        )
    }

    /// Opens a `session` channel and installs the handlers returned by `initialize`.
    func openSessionChannel(initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) async throws -> Channel {
        try await withChannelOpenTimeout { [sshHandler, channel] in
            channel.eventLoop.flatSubmit {
                let created = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.value.createChannel(created, channelType: .session) { child, type in
                    guard case .session = type else { return child.eventLoop.makeFailedFuture(SessionError.channelFailed("unexpected channel type")) }
                    return initialize(child)
                }
                return created.futureResult
            }
        }
    }

    /// Opens a `direct-tcpip` channel to `host:port` through this connection.
    func openDirectTCPIP(host: String, port: Int, initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) async throws -> Channel {
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        return try await withChannelOpenTimeout { [sshHandler, channel] in
            channel.eventLoop.flatSubmit {
                let created = channel.eventLoop.makePromise(of: Channel.self)
                sshHandler.value.createChannel(
                    created,
                    channelType: .directTCPIP(.init(targetHost: host, targetPort: port, originatorAddress: originator))
                ) { child, type in
                    guard case .directTCPIP = type else { return child.eventLoop.makeFailedFuture(SessionError.channelFailed("unexpected channel type")) }
                    return initialize(child)
                }
                return created.futureResult
            }
        }
    }

    /// Closes the transport, and the bastion behind it.
    func close() async {
        try? await channel.close()
        if let jumpHost { await jumpHost.close() }
    }

    private func withChannelOpenTimeout(_ open: @escaping @Sendable () -> EventLoopFuture<Channel>) async throws -> Channel {
        let future = open()
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(15)) {
            // Fail the open attempt by closing the transport; the awaiting call then throws.
            self.channel.close(promise: nil)
        }
        defer { timeout.cancel() }
        return try await future.get()
    }
}

// MARK: - Building connections

/// Everything needed to open one hop.
struct HopParameters: Sendable {
    var endpoint: HostEndpoint
    var username: String
    var credential: SSHCredential
    /// Called when the server rejected a password; returns the replacement.
    var passwordRetry: (@Sendable () async -> String?)?
    var hostKey: TOFUHostKeyValidator.Configuration
    var timeout: Duration
    var report: @Sendable (ConnectPhase) -> Void
}

enum SSHConnector {
    /// Opens the TCP connection (or forwarded channel), performs the SSH handshake and authenticates.
    static func open(_ hop: HopParameters, through jumpHost: SSHConnection? = nil) async throws -> SSHConnection {
        let parts = PartsBox()
        let channel: Channel

        do {
            if let jumpHost {
                hop.report(.handshake)
                channel = try await jumpHost.openDirectTCPIP(host: hop.endpoint.host, port: hop.endpoint.port) { child in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(SSHChannelDataCodec())
                        parts.set(try installSSHHandlers(on: child, hop: hop))
                    }
                }
            } else {
                hop.report(.resolving)
                channel = try await tcpConnect(hop) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        parts.set(try installSSHHandlers(on: channel, hop: hop))
                    }
                }
                hop.report(.handshake)
            }
        }

        guard let installed = parts.value else {
            try? await channel.close()
            throw SessionError.channelFailed("SSH pipeline was not installed")
        }

        do {
            try await installed.handshake.authenticated.get()
        } catch {
            try? await channel.close()
            // Prefer a precise reason over the generic "closed" error that follows a validator abort.
            throw await Self.refineHandshakeError(error, installed: installed)
        }

        return SSHConnection(
            channel: channel, sshHandler: installed.sshHandler, jumpHost: jumpHost, hello: installed.hello,
            authDelegate: installed.auth, clientKexNames: installed.kexNames, clientCipherNames: installed.cipherNames
        )
    }

    // MARK: Pipeline

    private struct Installed: Sendable {
        var handshake: HandshakeHandler
        var sshHandler: NIOLoopBoundBox<NIOSSHHandler>
        var hello: ServerHelloBox
        var auth: ClientAuthDelegate
        var kexNames: [String]
        var cipherNames: [String]
    }

    private final class PartsBox: Sendable {
        private let storage = Mutex<Installed?>(nil)
        var value: Installed? { storage.withLock { $0 } }
        func set(_ installed: Installed) { storage.withLock { $0 = installed } }
    }

    /// Adds the sniffer, NIOSSH and the handshake handler. Must run on the channel's event loop.
    private static func installSSHHandlers(on channel: Channel, hop: HopParameters) throws -> Installed {
        let hello = ServerHelloBox()
        let handshake = HandshakeHandler(loop: channel.eventLoop, timeout: hop.timeout)

        let auth = ClientAuthDelegate(
            username: hop.username,
            credential: hop.credential,
            passwordRetry: hop.passwordRetry.map { retry in
                { @Sendable in
                    handshake.pauseTimeout()
                    defer { handshake.resumeTimeout() }
                    return await retry()
                }
            },
            onAttempt: { hop.report(.authenticating) }
        )

        let report = hop.report
        let validator = TOFUHostKeyValidator(
            hop.hostKey,
            onPresented: { _ in report(.hostKey) },
            onPrompt: { waiting in waiting ? handshake.pauseTimeout() : handshake.resumeTimeout() }
        )

        var configuration = SSHClientConfiguration(userAuthDelegate: auth, serverAuthDelegate: validator)
        configuration.hostname = hop.endpoint.host
        applyExtraAlgorithms(to: &configuration)

        let sshHandler = NIOSSHHandler(role: .client(configuration), allocator: channel.allocator, inboundChildChannelInitializer: nil)
        try channel.pipeline.syncOperations.addHandlers([ServerHelloSniffer(box: hello), sshHandler, handshake])

        return Installed(
            handshake: handshake, sshHandler: NIOLoopBoundBox(sshHandler, eventLoop: channel.eventLoop), hello: hello, auth: auth,
            kexNames: configuration.keyExchangeAlgorithms.flatMap { $0.keyExchangeAlgorithmNames.map(String.init) },
            cipherNames: configuration.transportProtectionSchemes.map { $0.cipherName }
        )
    }

    /// NIOSSH ships curve25519/ECDH and AES-GCM. Citadel adds AES-CTR and DH group 14 (SHA-256), which
    /// older appliances still need. They are appended, so they are only used when nothing better matches.
    /// Legacy SHA-1 key exchange is deliberately not enabled.
    private static func applyExtraAlgorithms(to configuration: inout SSHClientConfiguration) {
        NIOSSHAlgorithms.register(transportProtectionScheme: AES128CTR.self)
        NIOSSHAlgorithms.register(keyExchangeAlgorithm: DiffieHellmanGroup14Sha256.self)
        configuration.transportProtectionSchemes.append(AES128CTR.self)
        configuration.keyExchangeAlgorithms.append(DiffieHellmanGroup14Sha256.self)
    }

    /// Turns a generic failure into the specific one the validator or auth delegate raised.
    private static func refineHandshakeError(_ error: any Error, installed: Installed) async -> any Error {
        if let nio = error as? NIOSSHError, nio.type == .keyExchangeNegotiationFailure,
           let kexInit = installed.hello.value.kexInit,
           let mismatch = AlgorithmNegotiation.firstMismatch(clientKex: installed.kexNames, clientCiphers: installed.cipherNames, server: kexInit) {
            return SessionError.noCommonAlgorithm(kind: mismatch.kind, offered: mismatch.offered)
        }
        return error
    }

    // MARK: TCP

    private static func tcpConnect(_ hop: HopParameters, initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) async throws -> Channel {
        let host = hop.endpoint.host
        let addresses = try await resolve(host: host, port: hop.endpoint.port, timeout: hop.timeout)
        hop.report(.tcp)

        let clock = ContinuousClock()
        let start = clock.now
        var lastError: (any Error)?
        for (index, address) in addresses.enumerated() {
            let remaining = hop.timeout - (clock.now - start)
            guard remaining > .zero else { break }
            let left = addresses.count - index
            // Spread the budget over the remaining addresses, but give each a fair chance.
            let attempt = min(remaining, max(.seconds(3), remaining / left))
            do {
                return try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .connectTimeout(.nanoseconds(Int64(attempt.components.seconds) * 1_000_000_000))
                    .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
                    .channelInitializer(initialize)
                    .connect(to: address)
                    .get()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ConnectTimeoutError(seconds: Int(hop.timeout.components.seconds))
    }

    /// `getaddrinfo` off the cooperative pool, abandoned (not cancelled) on timeout.
    private static func resolve(host: String, port: Int, timeout: Duration) async throws -> [SocketAddress] {
        try await withCheckedThrowingContinuation { continuation in
            let done = Mutex(false)
            let resume: @Sendable (Result<[SocketAddress], any Error>) -> Void = { result in
                let first = done.withLock { flag -> Bool in
                    if flag { return false }
                    flag = true
                    return true
                }
                if first { continuation.resume(with: result) }
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let addresses = try getAddresses(host: host, port: port)
                    resume(addresses.isEmpty ? .failure(DNSResolutionError(host: host)) : .success(addresses))
                } catch {
                    resume(.failure(DNSResolutionError(host: host)))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(timeout.components.seconds) * 1_000_000_000)) {
                resume(.failure(DNSResolutionError(host: host)))
            }
        }
    }
}

struct DNSResolutionError: Error, Equatable {
    var host: String
}

/// Converts between `SSHChannelData` (what NIOSSH child channels carry) and plain `ByteBuffer`s, so a second
/// NIOSSH pipeline can run inside a `direct-tcpip` channel.
final class SSHChannelDataCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        // handlerAdded runs on the event loop, so the synchronous option API is safe.
        do { try context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true) } catch { context.fireErrorCaught(error) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = channelData.data, case .channel = channelData.type else {
            context.fireErrorCaught(SessionError.channelFailed("unexpected channel data"))
            return
        }
        context.fireChannelRead(wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let bytes = unwrapOutboundIn(data)
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))), promise: promise)
    }
}
