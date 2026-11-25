import Foundation
import Synchronization

/// Remote bytes on their way to the terminal, with flow control.
///
/// The network side `push`es chunks; the terminal's `AsyncStream` pulls them with `next()`. The pipe counts the
/// bytes nobody has consumed yet. Above `highWater` it tells the transport to stop reading (`setReading(false)`),
/// which keeps SSH from reopening the channel window so the server stops sending; once the consumer has
/// drained below `lowWater` reading resumes. A slow terminal (or a `yes` flood) therefore costs bounded memory.
final class OutputPipe: Sendable {
    private struct State {
        var chunks: [Data] = []
        var head = 0
        var pending = 0
        var waiter: (id: UInt64, continuation: CheckedContinuation<Data?, Never>)?
        var nextWaiterID: UInt64 = 0
        var finished = false
        var reading = true
    }

    let highWater: Int
    let lowWater: Int
    private let state = Mutex(State())
    private let control = Mutex<(@Sendable (Bool) -> Void)?>(nil)

    init(highWater: Int = 4 * 1024 * 1024, lowWater: Int = 1 * 1024 * 1024) {
        self.highWater = highWater
        self.lowWater = lowWater
    }

    /// Bytes pushed but not yet consumed.
    var pendingBytes: Int { state.withLock { $0.pending } }

    /// Installs (or removes) the callback that starts and stops reading on the current connection.
    /// A new connection always starts out reading.
    func setReadControl(_ callback: (@Sendable (Bool) -> Void)?) {
        state.withLock { $0.reading = true }
        control.withLock { $0 = callback }
    }

    func push(_ data: Data) {
        guard !data.isEmpty else { return }
        enum Action { case deliver(CheckedContinuation<Data?, Never>), pause, none }
        let action = state.withLock { state -> Action in
            if let waiter = state.waiter {
                state.waiter = nil
                return .deliver(waiter.continuation)
            }
            state.chunks.append(data)
            state.pending += data.count
            if state.pending >= highWater, state.reading {
                state.reading = false
                return .pause
            }
            return .none
        }
        switch action {
        case .deliver(let continuation): continuation.resume(returning: data)
        case .pause: control.withLock { $0 }?(false)
        case .none: break
        }
    }

    /// The next chunk, or `nil` once finished or when the awaiting task is cancelled.
    func next() async -> Data? {
        if let ready = take() { return ready }

        let id = state.withLock { state -> UInt64 in state.nextWaiterID += 1; return state.nextWaiterID }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                enum Outcome { case wait, finished, ready(Data) }
                let outcome = state.withLock { state -> Outcome in
                    if state.head < state.chunks.count { return .ready(popLocked(&state)) }
                    if state.finished { return .finished }
                    state.waiter = (id, continuation)
                    return .wait
                }
                switch outcome {
                case .wait:
                    // The cancellation handler may have run before the waiter was registered.
                    if Task.isCancelled { cancelWaiter(id) }
                case .finished: continuation.resume(returning: nil)
                case .ready(let data):
                    continuation.resume(returning: data)
                    resumeReadingIfDrained()
                }
            }
        } onCancel: {
            cancelWaiter(id)
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        let continuation = state.withLock { state -> CheckedContinuation<Data?, Never>? in
            guard let waiter = state.waiter, waiter.id == id else { return nil }
            state.waiter = nil
            return waiter.continuation
        }
        continuation?.resume(returning: nil)
    }

    /// Ends the stream: the consumer drains what is queued, then gets `nil`.
    func finish() {
        let continuation = state.withLock { state -> CheckedContinuation<Data?, Never>? in
            state.finished = true
            let waiter = state.waiter?.continuation
            state.waiter = nil
            return waiter
        }
        continuation?.resume(returning: nil)
    }

    // MARK: Internals

    private func take() -> Data? {
        let data = state.withLock { state -> Data? in
            state.head < state.chunks.count ? popLocked(&state) : nil
        }
        if data != nil { resumeReadingIfDrained() }
        return data
    }

    private func popLocked(_ state: inout State) -> Data {
        let data = state.chunks[state.head]
        state.chunks[state.head] = Data()
        state.head += 1
        state.pending -= data.count
        // Compact occasionally so the array does not grow without bound.
        if state.head > 64, state.head * 2 > state.chunks.count {
            state.chunks.removeFirst(state.head)
            state.head = 0
        }
        return data
    }

    private func resumeReadingIfDrained() {
        let resume = state.withLock { state -> Bool in
            if !state.reading, state.pending <= lowWater {
                state.reading = true
                return true
            }
            return false
        }
        if resume { control.withLock { $0 }?(true) }
    }
}
