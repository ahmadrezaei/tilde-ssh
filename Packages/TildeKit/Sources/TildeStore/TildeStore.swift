import Foundation

public enum TildeStoreModule { public static let name = "TildeStore" }

/// Errors raised by the repositories for requests that would leave the store inconsistent.
public enum StoreError: Error, Equatable, Sendable {
    /// The key is still used by `count` servers; reassign them first.
    case keyInUse(serverCount: Int)
    /// A value failed validation (empty host, port out of range, ...).
    case invalidValue(String)
    /// `trust(replacing: false)` was asked to pin a second, different key for an algorithm that already has one.
    case differentKeyAlreadyPinned
}
