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
/// It works on the byte stream so it needs nothing from `TerminalSurface`: a bracketed paste
/// (`ESC[200~ ... ESC[201~`, possibly split over several `send` calls) with any newline in it, or a single
/// `send` carrying two or more non-empty lines, is a paste. A lone Return or a one-line snippet is never
/// held. While a confirmation is open, later keystrokes queue behind it so ordering is preserved.
///
/// If WS4 adds a native paste hook to `TerminalSurface`, this wrapper can go.
final class PasteGuardIO: TerminalIO, Sendable {
    private let base: any TerminalIO
    private let shouldConfirm: @Sendable () -> Bool
    private let confirm: @Sendable (String) async -> Bool

    private struct State {
        var collecting: Data?
        var awaiting = false
        var queue: [Data] = []
    }
    private let state = Mutex(State())

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
        enum Outcome { case forward, hold, paste(Data) }
        let outcome = state.withLock { s -> Outcome in
            if s.awaiting {
                s.queue.append(bytes)
                return .hold
            }
            if var collected = s.collecting {
                collected.append(bytes)
                if collected.range(of: PasteGuardPolicy.bracketEnd) != nil {
                    s.collecting = nil
                    return .paste(collected)
                }
                s.collecting = collected
                return .hold
            }
            if bytes.starts(with: PasteGuardPolicy.bracketStart) {
                if bytes.range(of: PasteGuardPolicy.bracketEnd) != nil { return .paste(bytes) }
                s.collecting = bytes
                return .hold
            }
            guard bytes.count > 1 else { return .forward }
            let text = String(decoding: bytes, as: UTF8.self)
            return PasteGuardPolicy.lines(of: text).count >= 2 ? .paste(bytes) : .forward
        }

        switch outcome {
        case .forward:
            base.send(bytes)
        case .hold:
            break
        case .paste(let data):
            let text = PasteGuardPolicy.payload(of: data)
            let bracketed = data.starts(with: PasteGuardPolicy.bracketStart)
            let isMultiline = bracketed ? PasteGuardPolicy.containsNewline(text) : PasteGuardPolicy.lines(of: text).count >= 2
            guard isMultiline, shouldConfirm() else {
                base.send(data)
                return
            }
            state.withLock { $0.awaiting = true }
            Task { [self] in
                let approved = await confirm(text)
                let queued = state.withLock { s -> [Data] in
                    s.awaiting = false
                    defer { s.queue = [] }
                    return s.queue
                }
                if approved { base.send(data) }
                for pending in queued { base.send(pending) }
            }
        }
    }
}
