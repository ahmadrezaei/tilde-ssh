import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Synchronization
import TildeCore

/// Runs a single command on an open connection through an `exec` channel (no PTY).
enum ExecRunner {
    /// Output beyond this is dropped (the command keeps running to completion).
    static let maximumOutput = 4 * 1024 * 1024

    private final class Collector: Sendable {
        private let storage = Mutex(Data())
        func append(_ data: Data) {
            storage.withLock { buffer in
                if buffer.count < ExecRunner.maximumOutput { buffer.append(data.prefix(ExecRunner.maximumOutput - buffer.count)) }
            }
        }
        var data: Data { storage.withLock { $0 } }
    }

    /// - Returns: standard output and the exit status (`-1` when the server reported none, e.g. a killed process).
    static func run(_ command: String, on connection: SSHConnection, timeout: Duration) async throws -> (stdout: Data, exitStatus: Int) {
        let loop = connection.channel.eventLoop
        let collector = Collector()
        let ended = loop.makePromise(of: ChannelClose.self)

        let channel: SSHSessionChannel
        do {
            channel = try await SSHSessionChannel.open(
                on: connection,
                onOutput: { data, isStandardError in if !isStandardError { collector.append(data) } },
                onClose: { ended.succeed($0) }
            )
        } catch {
            ended.fail(error)
            throw error
        }

        do {
            guard try await channel.request(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), wantReply: true) else {
                throw SessionError.channelFailed("The server refused to run the command.")
            }
            let close = try await withLoopTimeout(loop: loop, timeout: timeout) { try await ended.futureResult.get() }
            return (collector.data, close.exitStatus ?? -1)
        } catch is LoopTimeoutError {
            await channel.close()
            throw SessionError.timeout(seconds: Int(timeout.components.seconds))
        } catch {
            await channel.close()
            throw error
        }
    }
}
