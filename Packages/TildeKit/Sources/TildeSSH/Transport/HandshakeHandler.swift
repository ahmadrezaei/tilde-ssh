import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// Thrown when the connection does not reach "authenticated" in time (excluding time spent waiting for a human).
struct ConnectTimeoutError: Error, Equatable {
    var seconds: Int
}

/// Completes `authenticated` when `UserAuthSuccessEvent` arrives, or fails it on a pipeline error, a closed
/// channel, or a timeout. Unlike Citadel's built-in handler (hard-wired to 10 s), the timeout here can be paused
/// while a host key or password prompt is on screen.
///
/// `@unchecked Sendable`: all mutable state is confined to the channel's event loop; `pauseTimeout` /
/// `resumeTimeout` hop onto it before touching anything.
final class HandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let loop: any EventLoop
    private let promise: EventLoopPromise<Void>
    private let timeout: TimeAmount
    private var completed = false
    private var deadline: NIODeadline
    /// What is left of the timeout while paused.
    private var remaining: TimeAmount
    private var timer: Scheduled<Void>?
    private var pauseCount = 0

    /// Fulfilled when the connection is authenticated.
    var authenticated: EventLoopFuture<Void> { promise.futureResult }

    init(loop: any EventLoop, timeout: Duration) {
        self.loop = loop
        self.promise = loop.makePromise(of: Void.self)
        self.timeout = .nanoseconds(Int64(timeout.components.seconds) * 1_000_000_000 + timeout.components.attoseconds / 1_000_000_000)
        self.deadline = .now() + self.timeout
        self.remaining = self.timeout
        loop.execute { [self] in arm(in: self.timeout) }
    }

    // MARK: Timeout control (any thread)

    /// Stops the clock, e.g. while a prompt is showing. Calls nest.
    func pauseTimeout() {
        loop.execute { [self] in
            pauseCount += 1
            guard pauseCount == 1, let timer else { return }
            timer.cancel()
            self.timer = nil
            remaining = max(.milliseconds(1), deadline - .now())
        }
    }

    func resumeTimeout() {
        loop.execute { [self] in
            pauseCount = max(0, pauseCount - 1)
            guard pauseCount == 0, !completed, timer == nil else { return }
            arm(in: remaining)
        }
    }

    // MARK: Event-loop confined

    private func arm(in delay: TimeAmount) {
        timer?.cancel()
        deadline = .now() + delay
        let seconds = max(1, Int(timeout.nanoseconds / 1_000_000_000))
        timer = loop.scheduleTask(in: delay) { [self] in
            finish(.failure(ConnectTimeoutError(seconds: seconds)))
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard !completed else { return }
        completed = true
        timer?.cancel()
        timer = nil
        promise.completeWith(result)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            finish(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(ChannelError.ioOnClosedChannel))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish(.failure(ChannelError.ioOnClosedChannel))
    }
}
