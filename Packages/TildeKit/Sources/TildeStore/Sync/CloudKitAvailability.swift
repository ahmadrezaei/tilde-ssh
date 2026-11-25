import Foundation
#if os(macOS)
import Security
#endif

/// Decides whether a CloudKit-backed store can be created in this process.
///
/// Creating an `NSPersistentCloudKitContainer` in a build that lacks the iCloud entitlement (unsigned CI and
/// simulator builds, forks without a container) can abort the process with an Objective-C exception that
/// Swift cannot catch, so the factory asks here first and falls back to a local store.
public enum CloudKitAvailability {
    /// Set to `1` to force local-only stores (UI tests, debugging without an iCloud account).
    public static let disableEnvironmentVariable = "TILDE_DISABLE_CLOUDKIT"

    /// `true` when the environment forces local-only stores.
    public static var isDisabledByEnvironment: Bool {
        ProcessInfo.processInfo.environment[disableEnvironmentVariable] == "1"
    }

    /// `true` when the user is signed in to iCloud on this device (`ubiquityIdentityToken` is non-nil).
    public static var isSignedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    /// Whether the app is entitled to use `containerID`.
    ///
    /// macOS reads the code-signing entitlement of the running process. iOS has no public API for that, so it
    /// reports `true` and relies on `isSignedIn` and the environment override.
    public static func isEntitled(to containerID: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerID) ?? false
        #else
        return true
        #endif
    }

    /// `true` when a CloudKit store for `containerID` should be attempted.
    public static func canUseCloudKit(containerID: String) -> Bool {
        !isDisabledByEnvironment && isEntitled(to: containerID) && isSignedIn
    }
}
