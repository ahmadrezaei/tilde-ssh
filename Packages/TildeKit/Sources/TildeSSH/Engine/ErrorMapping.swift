import Foundation
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import TildeCore

/// The user declined a password prompt; the session ends quietly instead of showing an error banner.
struct ConnectCancelledError: Error, Equatable {}

/// Maps whatever NIO, NIOSSH or our own handlers threw into the contract's `SessionError`.
enum SessionErrorMapper {
    static func map(_ error: any Error, host: String, timeoutSeconds: Int) -> SessionError {
        switch error {
        case let error as SessionError:
            return error
        case let error as DNSResolutionError:
            return .dnsFailure(host: error.host)
        case let error as ConnectTimeoutError:
            return .timeout(seconds: error.seconds)
        case let error as AuthRejectedError:
            return .authFailed(method: error.method, serverAllows: error.serverAllows)
        case is HostKeyRejectedError:
            return .hostKeyRejected
        case let error as HostKeyMismatchError:
            return .hostKeyMismatch(challengeID: error.challenge.id)
        case let error as ChannelError:
            switch error {
            case .connectTimeout: return .timeout(seconds: timeoutSeconds)
            case .ioOnClosedChannel, .alreadyClosed, .eof, .outputClosed, .inputClosed: return .networkLost
            default: return .underlying(String(describing: error))
            }
        case let error as NIOConnectionError:
            return mapConnectionError(error, host: host, timeoutSeconds: timeoutSeconds)
        case let error as IOError:
            return mapErrno(error.errnoCode, timeoutSeconds: timeoutSeconds) ?? .underlying(String(describing: error))
        case let error as NIOSSHError:
            switch error.type {
            case .tcpShutdown:
                return .networkLost
            case .keyExchangeNegotiationFailure:
                return .noCommonAlgorithm(kind: "kex", offered: [])
            default:
                return .underlying(String(describing: error))
            }
        default:
            return .underlying(String(describing: error))
        }
    }

    private static func mapConnectionError(_ error: NIOConnectionError, host: String, timeoutSeconds: Int) -> SessionError {
        if error.connectionErrors.isEmpty, error.dnsAError != nil || error.dnsAAAAError != nil {
            return .dnsFailure(host: host)
        }
        for failure in error.connectionErrors {
            if let io = failure.error as? IOError, let mapped = mapErrno(io.errnoCode, timeoutSeconds: timeoutSeconds) {
                return mapped
            }
        }
        return .underlying(String(describing: error))
    }

    private static func mapErrno(_ code: CInt, timeoutSeconds: Int) -> SessionError? {
        switch code {
        case ECONNREFUSED: .refused
        case ETIMEDOUT: .timeout(seconds: timeoutSeconds)
        case ECONNRESET, EPIPE, ENOTCONN, ECONNABORTED, ENETDOWN, ENETUNREACH: .networkLost
        case EHOSTUNREACH: .networkLost
        default: nil
        }
    }

    /// Failures worth retrying automatically after a connection was lost. Credentials, host keys and
    /// protocol problems will not fix themselves.
    static func isRetriable(_ error: SessionError) -> Bool {
        switch error {
        case .dnsFailure, .refused, .timeout, .networkLost: true
        // Unclassified failures (an unreadable key, a pin that could not be saved) will not fix themselves.
        case .underlying: false
        case .hostKeyMismatch, .hostKeyRejected, .authFailed, .secretUnavailable, .noCommonAlgorithm, .channelFailed: false
        }
    }
}
