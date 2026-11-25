import Foundation
import Observation
import TildeCore

/// Drives the status dot and latency in the server list (design section 4.1, "Reachability probe").
///
/// A TCP connect through `ReachabilityProbe` (no SSH handshake, so no auth attempts and no log noise on servers). Runs for
/// visible rows, at most once per 60 s per host, with 3 concurrent probes and a 3 s timeout. The probe itself
/// decides to skip on Low Data Mode / cellular and answers `.skipped`.
@MainActor
@Observable
public final class ReachabilityMonitor {
    public enum Status: Equatable, Sendable {
        case unknown
        case probing
        case reachable(milliseconds: Int)
        case unreachable(reason: String)

        public var latencyMilliseconds: Int? {
            if case .reachable(let ms) = self { return ms }
            return nil
        }
    }

    public static let minimumInterval: TimeInterval = 60
    public static let maxConcurrent = 3
    public static let timeout: Duration = .seconds(3)

    private(set) var statuses: [String: Status] = [:]

    @ObservationIgnored private let prober: any ReachabilityProbe
    @ObservationIgnored private var lastProbe: [String: Date] = [:]
    @ObservationIgnored private var queue: [(key: String, target: ConnectionTarget)] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var running = 0
    @ObservationIgnored private let now: @MainActor () -> Date

    public init(prober: any ReachabilityProbe, now: @escaping @MainActor () -> Date = { Date() }) {
        self.prober = prober
        self.now = now
    }

    public func status(for target: ConnectionTarget) -> Status {
        statuses[Self.key(target)] ?? .unknown
    }

    /// Probes `target` unless it was probed in the last 60 s (or `force` is set, e.g. pull to refresh).
    public func refresh(_ target: ConnectionTarget, force: Bool = false) {
        guard Self.isEnabled else { return }
        let key = Self.key(target)
        if queued.contains(key) { return }
        if !force, let last = lastProbe[key], now().timeIntervalSince(last) < Self.minimumInterval { return }
        lastProbe[key] = now()
        queued.insert(key)
        queue.append((key, target))
        pump()
    }

    private func pump() {
        while running < Self.maxConcurrent, !queue.isEmpty {
            let item = queue.removeFirst()
            running += 1
            if statuses[item.key] == nil { statuses[item.key] = .probing }
            let prober = prober
            Task { [weak self] in
                let result = await prober.probe(item.target, timeout: Self.timeout)
                self?.finish(item.key, result)
            }
        }
    }

    private func finish(_ key: String, _ result: ProbeResult) {
        running -= 1
        queued.remove(key)
        switch result {
        case .reachable(let duration):
            statuses[key] = .reachable(milliseconds: Self.milliseconds(duration))
        case .unreachable(let reason):
            statuses[key] = .unreachable(reason: reason)
        case .skipped:
            statuses[key] = .unknown
        }
        pump()
    }

    static func key(_ target: ConnectionTarget) -> String { "\(target.host.lowercased()):\(target.port)" }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return max(0, Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000))
    }

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: TildeSettings.probeReachabilityKey) as? Bool ?? true
    }
}
