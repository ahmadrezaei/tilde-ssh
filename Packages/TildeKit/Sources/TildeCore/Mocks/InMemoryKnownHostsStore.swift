import Foundation

/// A `KnownHostsStore` backed by a dictionary, with the same lookup semantics as the real store:
/// no pin = `.unknown`; same algorithm + blob = `.trusted`; same algorithm, different blob = `.mismatch`.
public actor InMemoryKnownHostsStore: KnownHostsStore {
    private var pins: [String: [PinnedHostKey]] = [:]
    public private(set) var touched: [String] = []
    private let deviceName: String

    public init(deviceName: String = "Preview Device", pins: [HostEndpoint: [HostKey]] = [:]) {
        self.deviceName = deviceName
        for (endpoint, keys) in pins {
            self.pins[endpoint.canonical] = keys.map { PinnedHostKey(key: $0, firstSeenAt: .now, trustedOnDevice: deviceName) }
        }
    }

    public func lookup(_ endpoint: HostEndpoint, presented: HostKey) async -> HostKeyLookup {
        let pinned = pins[endpoint.canonical] ?? []
        if pinned.isEmpty { return .unknown }
        if pinned.contains(where: { $0.key.algorithm == presented.algorithm && $0.key.blobBase64 == presented.blobBase64 }) {
            return .trusted
        }
        let sameAlgorithm = pinned.filter { $0.key.algorithm == presented.algorithm }
        // A different algorithm than any pinned one is treated as a mismatch too (OpenSSH would
        // warn), so the UI never silently accepts an unexpected key type.
        return .mismatch(pinned: sameAlgorithm.isEmpty ? pinned : sameAlgorithm)
    }

    public func trust(_ key: HostKey, for endpoint: HostEndpoint, replacing: Bool) async throws {
        let entry = PinnedHostKey(key: key, firstSeenAt: .now, trustedOnDevice: deviceName)
        if replacing {
            pins[endpoint.canonical] = [entry]
        } else {
            pins[endpoint.canonical, default: []].append(entry)
        }
    }

    public func touch(_ endpoint: HostEndpoint) async { touched.append(endpoint.canonical) }

    /// Test helper.
    public func pinned(for endpoint: HostEndpoint) -> [PinnedHostKey] { pins[endpoint.canonical] ?? [] }
}
