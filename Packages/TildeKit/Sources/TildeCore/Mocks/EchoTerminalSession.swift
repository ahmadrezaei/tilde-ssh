import Foundation
import Synchronization

/// A `TerminalSession` for previews and tests. It "connects" after a short delay, prints a colourful
/// banner and a prompt, echoes typed input, and understands `clear`, `ls`, `exit` and Ctrl-C.
/// No network involved.
public final class EchoTerminalSession: TerminalSession {
    public let id: UUID
    public let server: ServerSnapshot
    public let output: AsyncStream<Data>

    private let outputContinuation: AsyncStream<Data>.Continuation
    private let stateBroadcaster = AsyncBroadcaster<SessionState>(initial: .idle)
    private let connectDelay: Duration
    private let failure: SessionError?

    private struct Input {
        var line = ""
        var escapeState = 0   // 0 none, 1 saw ESC, 2 inside CSI/SS3
        var cols = 80
        var rows = 24
    }
    private let input = Mutex(Input())

    public init(server: ServerSnapshot, id: UUID = UUID(), connectDelay: Duration = .milliseconds(300), failure: SessionError? = nil) {
        self.id = id
        self.server = server
        self.connectDelay = connectDelay
        self.failure = failure
        var continuation: AsyncStream<Data>.Continuation!
        output = AsyncStream { continuation = $0 }
        outputContinuation = continuation
    }

    deinit { outputContinuation.finish() }

    public var states: AsyncStream<SessionState> { stateBroadcaster.stream() }

    public func connect() async {
        stateBroadcaster.send(.connecting(phase: .tcp))
        try? await Task.sleep(for: connectDelay)
        if let failure {
            stateBroadcaster.send(.disconnected(.error(failure)))
            return
        }
        stateBroadcaster.send(.connecting(phase: .authenticating))
        stateBroadcaster.send(.connected(Self.mockInfo))
        emit("\u{1B}[2J\u{1B}[H")
        emit("\u{1B}[1;36mTilde\u{1B}[0m mock session to \u{1B}[1m\(server.target.username)@\(server.target.host)\u{1B}[0m\r\n")
        emit("\u{1B}[90mType anything. Commands: ls, clear, exit. Ctrl-C cancels.\u{1B}[0m\r\n")
        emitPrompt()
    }

    public func reconnect() async {
        await disconnect()
        await connect()
    }

    public func disconnect() async {
        stateBroadcaster.send(.disconnected(.userClosed))
    }

    public func latency() async -> Duration? { .milliseconds(23) }

    public func send(_ bytes: Data) {
        var out = Data()
        var finishedLine: String?
        input.withLock { s in
            for byte in bytes {
                if s.escapeState == 1 {
                    s.escapeState = (byte == 0x5B || byte == 0x4F) ? 2 : 0   // '[' or 'O'
                    continue
                }
                if s.escapeState == 2 {
                    if (0x40...0x7E).contains(byte) { s.escapeState = 0 }   // final byte of CSI
                    continue
                }
                switch byte {
                case 0x1B: s.escapeState = 1
                case 0x0D, 0x0A:
                    out.append(contentsOf: "\r\n".utf8)
                    finishedLine = s.line
                    s.line = ""
                case 0x7F, 0x08:
                    if !s.line.isEmpty {
                        s.line.removeLast()
                        out.append(contentsOf: "\u{8} \u{8}".utf8)
                    }
                case 0x03:
                    s.line = ""
                    out.append(contentsOf: "^C\r\n".utf8)
                    finishedLine = ""
                case 0x20...0x7E, 0x80...0xFF:
                    out.append(byte)
                    s.line.unicodeScalars.append(Unicode.Scalar(byte))
                default: break
                }
            }
        }
        if !out.isEmpty { outputContinuation.yield(out) }
        if let line = finishedLine { run(line) }
    }

    public func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        input.withLock { $0.cols = cols; $0.rows = rows }
    }

    /// The last size reported through `resize`, for tests.
    public var lastSize: (cols: Int, rows: Int) { input.withLock { ($0.cols, $0.rows) } }

    // MARK: Private

    private static let mockInfo = ConnectionInfo(
        serverVersion: "SSH-2.0-OpenSSH_9.6",
        kex: "curve25519-sha256",
        cipher: "aes256-gcm@openssh.com",
        authenticatedWith: "ssh-ed25519",
        latency: .milliseconds(23)
    )

    private func emit(_ string: String) { outputContinuation.yield(Data(string.utf8)) }

    private func emitPrompt() {
        emit("\u{1B}[1;32m\(server.target.username)@\(server.name)\u{1B}[0m:\u{1B}[1;34m~\u{1B}[0m$ ")
    }

    private func run(_ line: String) {
        let command = line.trimmingCharacters(in: .whitespaces)
        switch command {
        case "":
            break
        case "clear":
            emit("\u{1B}[2J\u{1B}[H")
        case "ls":
            emit("\u{1B}[1;34mbackups\u{1B}[0m  \u{1B}[1;34mlogs\u{1B}[0m  \u{1B}[1;32mdeploy.sh\u{1B}[0m  notes.txt  \u{1B}[1;31marchive.tar.gz\u{1B}[0m\r\n")
        case "exit", "logout":
            emit("logout\r\n")
            stateBroadcaster.send(.disconnected(.exited(status: 0)))
            return
        default:
            emit("\u{1B}[33mecho:\u{1B}[0m \(command)\r\n")
        }
        emitPrompt()
    }
}
