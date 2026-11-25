import Foundation
import SwiftData
import TildeCore
@testable import TildeStore

/// A fresh in-memory container per test.
func makeContainer() throws -> ModelContainer { try ModelContainerFactory.make(.inMemory) }

extension HostKey {
    static func sample(_ algorithm: String = "ssh-ed25519", blob: String = "AAAA", fingerprint: String? = nil) -> HostKey {
        HostKey(algorithm: algorithm, blobBase64: blob, fingerprintSHA256: fingerprint ?? "SHA256:\(blob)")
    }
}

/// A mutable clock for throttling tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
