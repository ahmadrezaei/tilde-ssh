import Foundation
import Synchronization

/// Replay-on-subscribe fan-out for `TerminalSession.states`.
///
/// Every `stream()` yields the current value first and every later value in order. Unlike the mock in
/// `TildeCore`, values are yielded while the lock is held, so concurrent `send` calls and new subscriptions
/// cannot interleave: each subscriber sees a consistent, ordered sequence ending at the latest value.
/// (`AsyncStream.Continuation.yield` never blocks with an unbounded buffer and never re-enters this lock.)
final class StateBroadcaster<Element: Sendable>: Sendable {
    private struct State {
        var current: Element
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    }

    private let state: Mutex<State>

    init(initial: Element) { state = Mutex(State(current: initial)) }

    var current: Element { state.withLock { $0.current } }

    func send(_ value: Element) {
        state.withLock { state in
            state.current = value
            for continuation in state.continuations.values { continuation.yield(value) }
        }
    }

    func stream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let key = UUID()
            state.withLock { state in
                state.continuations[key] = continuation
                continuation.yield(state.current)
            }
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.continuations.removeValue(forKey: key) }
            }
        }
    }
}
