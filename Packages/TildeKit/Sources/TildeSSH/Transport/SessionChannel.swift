import Foundation
import NIOCore
@preconcurrency import NIOSSH
import TildeCore

/// Why a session channel ended.
struct ChannelClose: Sendable, Equatable {
    var exitStatus: Int?
    var exitSignal: String?
    /// Set when the channel died from an error rather than a clean close.
    var error: String?
}

/// Receives data and lifecycle events of one SSH session channel (shell or exec) and matches the server's
/// SUCCESS / FAILURE replies to the requests we sent, in order.
///
/// `@unchecked Sendable`: every mutable property is only touched on the channel's event loop
/// (NIO callbacks, or the `request` method which hops there first).
final class SessionChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let onOutput: @Sendable (Data, _ isStandardError: Bool) -> Void
    private let onClose: @Sendable (ChannelClose) -> Void

    private var replyWaiters: [EventLoopPromise<Bool>] = []
    private var exitStatus: Int?
    private var exitSignal: String?
    private var failure: String?
    private var closeReported = false

    init(onOutput: @escaping @Sendable (Data, Bool) -> Void, onClose: @escaping @Sendable (ChannelClose) -> Void) {
        self.onOutput = onOutput
        self.onClose = onClose
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // handlerAdded runs on the event loop, so the synchronous option API is safe.
        do { try context.channel.syncOptions?.setOption(ChannelOptions.allowRemoteHalfClosure, value: true) } catch { context.fireErrorCaught(error) }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = channelData.data else { return }
        switch channelData.type {
        case .channel:
            onOutput(Data(buffer.readableBytesView), false)
        case .stdErr:
            onOutput(Data(buffer.readableBytesView), true)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if !replyWaiters.isEmpty { replyWaiters.removeFirst().succeed(true) }
        case is ChannelFailureEvent:
            if !replyWaiters.isEmpty { replyWaiters.removeFirst().succeed(false) }
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        case let signal as SSHChannelRequestEvent.ExitSignal:
            exitSignal = signal.signalName
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failure = String(describing: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        for waiter in replyWaiters { waiter.fail(ChannelError.ioOnClosedChannel) }
        replyWaiters.removeAll()
        guard !closeReported else { return }
        closeReported = true
        onClose(ChannelClose(exitStatus: exitStatus, exitSignal: exitSignal, error: failure))
        context.fireChannelInactive()
    }

    /// Sends a channel request. With `wantReply` the future yields the server's answer (`true` = SUCCESS).
    func request<Event: Sendable>(_ event: Event, wantReply: Bool, on channel: Channel) -> EventLoopFuture<Bool> {
        return channel.eventLoop.flatSubmit { [self] in
            let waiter = channel.eventLoop.makePromise(of: Bool.self)
            if wantReply { replyWaiters.append(waiter) }
            let written = channel.eventLoop.makePromise(of: Void.self)
            channel.triggerUserOutboundEvent(event, promise: written)
            written.futureResult.whenComplete { result in
                switch result {
                case .success:
                    if !wantReply { waiter.succeed(true) }
                case .failure(let error):
                    waiter.fail(error)
                }
            }
            return waiter.futureResult
        }
    }
}

/// A session channel on an `SSHConnection`.
final class SSHSessionChannel: Sendable {
    let channel: Channel
    private let handler: SessionChannelHandler

    private init(channel: Channel, handler: SessionChannelHandler) {
        self.channel = channel
        self.handler = handler
    }

    /// Opens a channel; `onOutput` receives remote bytes, `onClose` fires once when the channel ends.
    static func open(
        on connection: SSHConnection,
        onOutput: @escaping @Sendable (Data, Bool) -> Void,
        onClose: @escaping @Sendable (ChannelClose) -> Void
    ) async throws -> SSHSessionChannel {
        let handler = SessionChannelHandler(onOutput: onOutput, onClose: onClose)
        let channel = try await connection.openSessionChannel { child in
            child.pipeline.addHandler(handler)
        }
        return SSHSessionChannel(channel: channel, handler: handler)
    }

    /// Sends a request and, with `wantReply`, returns whether the server accepted it.
    @discardableResult
    func request<Event: Sendable>(_ event: Event, wantReply: Bool = true) async throws -> Bool {
        try await handler.request(event, wantReply: wantReply, on: channel).get()
    }

    /// Queues bytes for the remote side. Non-blocking; calls are delivered in order.
    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    /// Sends an SSH `window-change` request.
    func windowChange(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols, terminalRowHeight: rows, terminalPixelWidth: pixelWidth, terminalPixelHeight: pixelHeight
        )
        channel.triggerUserOutboundEvent(event, promise: nil)
    }

    /// Flow control: with `autoRead` off the channel stops delivering and stops granting the server more
    /// window, so the sender backs off. Turning it back on asks for the next read.
    func setReading(_ enabled: Bool) {
        let channel = channel
        channel.eventLoop.execute {
            try? channel.syncOptions?.setOption(ChannelOptions.autoRead, value: enabled)
            if enabled { channel.read() }
        }
    }

    func close() async {
        try? await channel.close()
    }

    /// Resolves when the channel has closed.
    var closeFuture: EventLoopFuture<Void> { channel.closeFuture }
}

/// `ExecRequest` is a plain struct of a `String` and a `Bool`, but NIOSSH does not mark it `Sendable`
/// (the other request types are). It is only passed to the channel's event loop.
extension SSHChannelRequestEvent.ExecRequest: @retroactive @unchecked Sendable {}
