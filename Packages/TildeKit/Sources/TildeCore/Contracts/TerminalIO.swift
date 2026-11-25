import Foundation

// MARK: - Terminal I/O (WS2 implements via TerminalSession; WS4 consumes)

public protocol TerminalIO: AnyObject, Sendable {
    /// Remote to screen bytes.
    var output: AsyncStream<Data> { get }
    /// Keyboard to remote. Non-blocking and ordered.
    func send(_ bytes: Data)
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)
}
