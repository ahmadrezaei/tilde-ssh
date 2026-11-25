import Foundation
#if os(macOS)
import Security
#endif

/// Decides whether a CloudKit-backed store can be created in this process.
///
/// Creating an `NSPersistentCloudKitContainer` or a `CKContainer` in a build that lacks the iCloud
/// entitlement (unsigned CI and simulator builds, forks without a container) can abort the process with an
/// Objective-C exception that Swift cannot catch, so the factory asks here first and falls back to a local
/// store.
///
/// This is a *capability* check, not a sign-in check. A signed-out user still gets the CloudKit-backed store
/// (it keeps working offline and starts syncing after sign-in); the account state is read asynchronously by
/// `SyncStatusMonitor` through `CKContainer.accountStatus`, because `ubiquityIdentityToken` is also nil when
/// iCloud Drive is off while CloudKit works.
public enum CloudKitAvailability {
    /// Set to `1` to force local-only stores (UI tests, debugging without an iCloud account).
    public static let disableEnvironmentVariable = "TILDE_DISABLE_CLOUDKIT"

    /// The Bool Info.plist key the app target sets (to `YES`, from `Config/Shared.xcconfig`) when it is signed
    /// with the iCloud entitlement. Required on iOS, where the entitlement cannot be read at run time; a
    /// missing key means "not capable".
    public static let infoPlistKey = "TildeCloudKitEnabled"

    /// `true` when the environment forces local-only stores.
    public static var isDisabledByEnvironment: Bool {
        ProcessInfo.processInfo.environment[disableEnvironmentVariable] == "1"
    }

    /// Whether this build may use CloudKit for `containerID`.
    ///
    /// - macOS: the process's code-signing entitlement lists the container.
    /// - iOS: there is no public API to read entitlements, so the `TildeCloudKitEnabled` Info.plist key
    ///   must be `true`. A missing key is `false`.
    public static func isEntitled(to containerID: String) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains(containerID) ?? false
        #else
        return infoPlistEnabled(Bundle.main.object(forInfoDictionaryKey: infoPlistKey))
        #endif
    }

    /// Interprets the Info.plist value: only a real `true` (Bool or the string `YES`/`true`) counts, so an
    /// unexpanded `$(VAR)` placeholder or a missing key is "not capable".
    static func infoPlistEnabled(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let text as String: return ["yes", "true", "1"].contains(text.lowercased())
        default: return false
        }
    }

    /// `true` when a CloudKit store for `containerID` should be attempted (and a `CKContainer` may be created).
    public static func canUseCloudKit(containerID: String) -> Bool {
        !isDisabledByEnvironment && isEntitled(to: containerID)
    }
}
