import Foundation
import Observation

// MARK: - App lock (WS3)

/// The app-level biometric lock. Implementations are `@Observable` so SwiftUI tracks `isLocked`.
@MainActor public protocol AppLocking: AnyObject, Observable {
    var isLocked: Bool { get }
    /// Prompts for Face ID / Touch ID / passcode. Returns `true` if unlocked.
    func unlock() async -> Bool
    func lockNow()
}
