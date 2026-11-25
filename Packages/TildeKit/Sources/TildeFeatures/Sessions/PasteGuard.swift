import Foundation
import Synchronization
import TildeCore

/// Pure paste-safety rules (design section 4.5, "Paste safety").
enum PasteGuardPolicy {
    static let bracketStart = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])   // ESC [ 200 ~
    static let bracketEnd = Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])     // ESC [ 201 ~

    /// Whether a paste to a server in `environment` must be confirmed under `mode`.
    static func requiresConfirmation(mode: PasteConfirmMode, environment: ServerEnvironment) -> Bool {
        switch mode {
        case .always: true
        case .never: false
        case .prodOnly: environment == .prod
        }
    }

    /// The non-empty lines of `text` (split on CR, LF or CRLF).
    static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }).map(String.init)
    }

    static func containsNewline(_ text: String) -> Bool { text.contains { $0 == "\n" || $0 == "\r" || $0 == "\r\n" } }

    /// The text between bracketed-paste markers (or the data itself if there are none).
    static func payload(of data: Data) -> String {
        var body = data
        if body.starts(with: bracketStart) { body.removeFirst(bracketStart.count) }
        if let range = body.range(of: bracketEnd) { body.removeSubrange(range.lowerBound...) }
        return String(decoding: body, as: UTF8.self)
    }
}

/// A `TerminalIO` wrapper that holds back multi-line pastes until the user confirms ("Paste 14 lines into
/// prod-api-01?").
///
/// It works on the byte stream so it needs nothing from `TerminalSurface`. A paste is either a bracketed paste
/// (`ESC[200~ ... ESC[201~`, possibly split over several `send` calls) or any multi-byte `send` that carries a
/// CR or LF (a paste of `rm -rf /` plus a newline is one line, and still runs the moment it arrives). A lone
/// Return, typed characters and Meta-key sequences (`ESC` first) are never held.
///
/// Every chunk goes through one ordered queue. While a confirmation is open, later chunks wait behind it and are
/// classified again when their turn comes, so a second paste is asked about too and keystrokes can never overtake
/// the paste in front of them.
///
/// If WS4 adds a native paste hook to `TerminalSurface`, this wrapper can go.
final class PasteGuardIO: TerminalIO, Sendable {
    private let base: any TerminalIO
    private let shouldConfirm: @Sendable () -> Bool
    private let confirm: @Sendable (String) async -> Bool

    private struct State {
        var collecting: Data?
        var queue: [Data] = []
        /// A drain loop owns the queue (running, or suspended on a confirmation).
        var draining = false
    }
    private let state = Mutex(State())

    private enum Step {
        case idle, skip
        case forward(Data)
        case paste(Data)
    }

    init(base: any TerminalIO, shouldConfirm: @escaping @Sendable () -> Bool, confirm: @escaping @Sendable (String) async -> Bool) {
        self.base = base
        self.shouldConfirm = shouldConfirm
        self.confirm = confirm
    }

    var output: AsyncStream<Data> { base.output }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        base.resize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    func send(_ bytes: Data) {
        let shouldDrain = state.withLock { s -> Bool in
            s.queue.append(bytes)
            if s.draining { return false }
            s.draining = true
            return true
        }
        if shouldDrain { drain() }
    }

    /// Processes the queue in order. Returns when it is empty, or when suspended on a confirmation (the task that
    /// finishes the confirmation calls `drain()` again).
    private func drain() {
        while true {
            let step = state.withLock { s -> Step in
                guard !s.queue.isEmpty else {
                    s.draining = false
                    return .idle
                }
                return Self.classify(s.queue.removeFirst(), &s)
            }
            switch step {
            case .idle:
                return
            case .skip:
                continue
            case .forward(let data):
                base.send(data)
            case .paste(let data):
                let text = PasteGuardPolicy.payload(of: data)
                guard PasteGuardPolicy.containsNewline(text), shouldConfirm() else {
                    base.send(data)
                    continue
                }
                Task { [self] in
                    if await confirm(text) { base.send(data) }
                    drain()
                }
                return
            }
        }
    }

    private static func classify(_ chunk: Data, _ s: inout State) -> Step {
        if var collected = s.collecting {
            collected.append(chunk)
            if collected.range(of: PasteGuardPolicy.bracketEnd) != nil {
                s.collecting = nil
                return .paste(collected)
            }
            s.collecting = collected
            return .skip
        }
        if chunk.starts(with: PasteGuardPolicy.bracketStart) {
            if chunk.range(of: PasteGuardPolicy.bracketEnd) != nil { return .paste(chunk) }
            s.collecting = chunk
            return .skip
        }
        // Single keystrokes and escape sequences (arrows, Meta-Return) are not pastes.
        guard chunk.count > 1, chunk.first != 0x1B else { return .forward(chunk) }
        let text = String(decoding: chunk, as: UTF8.self)
        return PasteGuardPolicy.containsNewline(text) ? .paste(chunk) : .forward(chunk)
    }
}
