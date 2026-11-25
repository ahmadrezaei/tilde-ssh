import Foundation

#if os(macOS)
import AppKit
import Carbon.HIToolbox
#endif

/// Session > Secure Keyboard Entry.
///
/// While enabled, macOS stops other processes from observing keystrokes typed into Tilde (the same switch Terminal
/// and iTerm2 offer). The preference is stored in `UserDefaults`; the system-wide secure input mode is only held
/// while Tilde is the active app, so it can never stay on after the user switches away.
///
/// On iOS and iPadOS this type exists so shared code compiles, and does nothing.
@MainActor
public final class SecureKeyboardEntry {
    /// The `UserDefaults` key behind the menu toggle. Use it with `@AppStorage` to mirror the state.
    public static let defaultsKey = "tilde.secureKeyboardEntry"

    /// The shared instance used by the menu and by the macOS `AppDelegate`.
    public static let shared = SecureKeyboardEntry()

    /// Whether the user wants secure keyboard entry on.
    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.defaultsKey) }
        set {
            defaults.set(newValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    private let defaults: UserDefaults
    private var holdingSystemLock = false

    /// - Parameter defaults: where the preference is stored. Tests pass a throwaway suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Starts following app activation. Call once at launch (macOS `applicationDidFinishLaunching`).
    public func install() {
        #if os(macOS)
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.release() }
        }
        apply()
        #endif
    }

    /// Releases the system lock. Call from `applicationWillTerminate`.
    public func shutdown() {
        release()
    }

    /// Brings the system state in line with the preference.
    public func apply() {
        #if os(macOS)
        if isEnabled {
            // Never take the system-wide lock while another app is in front; activation applies it later.
            guard NSApp.isActive else { return }
            guard !holdingSystemLock else { return }
            EnableSecureEventInput()
            holdingSystemLock = true
        } else {
            release()
        }
        #endif
    }

    private func release() {
        #if os(macOS)
        guard holdingSystemLock else { return }
        DisableSecureEventInput()
        holdingSystemLock = false
        #endif
    }
}
