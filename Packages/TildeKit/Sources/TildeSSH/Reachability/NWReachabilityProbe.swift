import Foundation
import Network
import Synchronization
import TildeCore

/// Measures how long a plain TCP connect to the server's SSH port takes (no SSH handshake, no credentials).
/// Drives the reachability dot and latency pill in the server list.
public struct NWReachabilityProbe: ReachabilityProbe {
    public init() {}

    public func probe(_ target: ConnectionTarget, timeout: Duration) async -> ProbeResult {
        guard !target.host.isEmpty, let port = NWEndpoint.Port(rawValue: UInt16(clamping: target.port)), target.port > 0 else {
            return .unreachable(reason: "Invalid address")
        }

        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        let clock = ContinuousClock()
        let start = clock.now
        let finished = Mutex(false)

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProbeResult, Never>) in
                let finish: @Sendable (ProbeResult) -> Void = { result in
                    let first = finished.withLock { done -> Bool in
                        if done { return false }
                        done = true
                        return true
                    }
                    guard first else { return }
                    connection.cancel()
                    continuation.resume(returning: result)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(.reachable(clock.now - start))
                    case .failed(let error), .waiting(let error):
                        // `.waiting` is how Network.framework reports a refused or unroutable connect.
                        finish(.unreachable(reason: Self.reason(for: error)))
                    case .cancelled:
                        finish(.unreachable(reason: "Cancelled"))
                    default:
                        break
                    }
                }
                connection.start(queue: .global(qos: .utility))

                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                    finish(.unreachable(reason: "No response"))
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Short human-readable text for the server list tooltip.
    static func reason(for error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Connection refused"
            case .ETIMEDOUT: return "No response"
            case .ENETUNREACH, .ENETDOWN: return "Network unreachable"
            case .EHOSTUNREACH: return "Host unreachable"
            default: return String(cString: strerror(code.rawValue))
            }
        case .dns:
            return "Can't resolve host"
        case .wifiAware:
            return "Unreachable"
        case .tls:
            return "TLS error"
        @unknown default:
            return "Unreachable"
        }
    }
}
