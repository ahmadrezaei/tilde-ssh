import Foundation
import Synchronization

/// Fan-out helper for mocks: every `stream()` call yields the current value first (replay-on-subscribe,
/// like `TerminalSession.states`) and then every later value. Thread-safe.
public final class AsyncBroadcaster<Element: Sendable>: Sendable {
    private struct State {
        var current: Element
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    }
    private let state: Mutex<State>

    public init(initial: Element) {
        state = Mutex(State(current: initial))
    }

    public var current: Element { state.withLock { $0.current } }

    public func send(_ value: Element) {
        let targets = state.withLock { s -> [AsyncStream<Element>.Continuation] in
            s.current = value
            return Array(s.continuations.values)
        }
        for c in targets { c.yield(value) }
    }

    public func stream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let key = UUID()
            let initial = state.withLock { s -> Element in
                s.continuations[key] = continuation
                return s.current
            }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                _ = self?.state.withLock { $0.continuations.removeValue(forKey: key) }
            }
        }
    }
}
