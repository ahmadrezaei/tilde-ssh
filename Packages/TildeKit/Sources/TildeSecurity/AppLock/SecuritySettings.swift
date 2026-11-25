import Foundation
import Observation

/// How long the app may stay in the background before App Lock re-engages.
public enum AppLockTimeout: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public var title: String {
        switch self {
        case .immediately: "Immediately"
        case .oneMinute: "After 1 minute"
        case .fiveMinutes: "After 5 minutes"
        case .fifteenMinutes: "After 15 minutes"
        }
    }
}

/// The security preferences from Settings > Security. Stored per device in `UserDefaults` (biometrics differ
/// per device, and nothing here is sensitive).
///
/// `strictHostChecking` and `allowLegacySSHRSA` are read by the SSH layer; `clipboardClearSeconds` by `SecureClipboard`.
@MainActor
@Observable
public final class SecuritySettings {
    /// The instance the app uses unless a test or preview injects its own.
    public static let shared = SecuritySettings()

    /// Clipboard clearing choices offered in Settings (0 = never).
    public static let clipboardClearChoices = [0, 30, 60, 120, 300]

    private enum Key {
        static let appLockEnabled = "tilde.security.appLockEnabled"
        static let lockTimeout = "tilde.security.lockTimeoutSeconds"
        static let hideContent = "tilde.security.hideContentInSwitcher"
        static let strictHostChecking = "tilde.security.strictHostChecking"
        static let clipboardClear = "tilde.security.clipboardClearSeconds"
        static let allowLegacySSHRSA = "tilde.security.allowLegacySSHRSA"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Require Face ID / Touch ID / Optic ID (or the device passcode) to open Tilde. Off by default.
    /// Change it through `AppLock.setEnabled(_:)`, which verifies authentication first.
    public var appLockEnabled: Bool {
        didSet { defaults.set(appLockEnabled, forKey: Key.appLockEnabled) }
    }

    /// Re-lock delay after the app leaves the foreground.
    public var lockTimeout: AppLockTimeout {
        didSet { defaults.set(lockTimeout.rawValue, forKey: Key.lockTimeout) }
    }

    /// Cover the window in the app switcher and screenshots-in-progress. On by default.
    public var hideContentInSwitcher: Bool {
        didSet { defaults.set(hideContentInSwitcher, forKey: Key.hideContent) }
    }

    /// Refuse hosts whose key is not already pinned or imported. Off by default.
    public var strictHostChecking: Bool {
        didSet { defaults.set(strictHostChecking, forKey: Key.strictHostChecking) }
    }

    /// Let RSA keys also sign with SHA-1 (`ssh-rsa`) after the SHA-2 variants fail. Some Dropbear/OpenWrt servers need
    /// it; SHA-1 signatures are weak, so it is off by default. Read by the SSH engine when a session is created.
    public var allowLegacySSHRSA: Bool {
        didSet { defaults.set(allowLegacySSHRSA, forKey: Key.allowLegacySSHRSA) }
    }

    /// Seconds before a copied secret is removed from the pasteboard; 0 disables clearing. Default 60.
    public var clipboardClearSeconds: Int {
        didSet { defaults.set(clipboardClearSeconds, forKey: Key.clipboardClear) }
    }

    /// The stored values, readable off the main actor (the SSH engine builds sessions from any context and must see the
    /// latest choice without holding the observable object).
    public nonisolated static func storedStrictHostChecking(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.strictHostChecking)
    }

    public nonisolated static func storedAllowLegacySSHRSA(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Key.allowLegacySSHRSA)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appLockEnabled = defaults.bool(forKey: Key.appLockEnabled)
        lockTimeout = AppLockTimeout(rawValue: defaults.object(forKey: Key.lockTimeout) as? Int ?? 0) ?? .immediately
        hideContentInSwitcher = defaults.object(forKey: Key.hideContent) as? Bool ?? true
        strictHostChecking = defaults.bool(forKey: Key.strictHostChecking)
        allowLegacySSHRSA = defaults.bool(forKey: Key.allowLegacySSHRSA)
        clipboardClearSeconds = defaults.object(forKey: Key.clipboardClear) as? Int ?? 60
    }
}
