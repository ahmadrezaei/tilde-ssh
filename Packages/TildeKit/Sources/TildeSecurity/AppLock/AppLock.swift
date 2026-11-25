import Foundation
import Observation
import SwiftUI
import TildeCore

/// Where the app is in its life cycle, as far as App Lock cares. `AppLockGate` maps `ScenePhase` onto it.
public enum AppLockPhase: Sendable, Equatable {
    case active, inactive, background

    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .inactive: self = .inactive
        case .background: self = .background
        @unknown default: self = .inactive
        }
    }
}

/// The app-level lock (docs/DESIGN.md section 6.4): LocalAuthentication with the device passcode as fallback, a
/// re-lock timeout and a privacy cover for the app switcher.
///
/// Live SSH sessions stay connected while locked; `AppLockGate` only covers the UI. If the device has no passcode
/// (so it cannot authenticate its owner at all), the lock cannot be enforced and opens without a prompt.
@MainActor
@Observable
public final class AppLock: AppLocking {
    /// The most recently created lock, so a Settings scene (a separate SwiftUI scene on macOS) can find it.
    public private(set) static weak var current: AppLock?

    public private(set) var isLocked: Bool
    /// `true` while the system prompt is on screen.
    public private(set) var isAuthenticating = false
    /// `true` after a failed or cancelled attempt, until the next success. Drives the lock screen's hint.
    public private(set) var lastAttemptFailed = false
    /// The app's life-cycle phase, combined from every scene that reports through `sceneDidChange(_:scene:)`: active
    /// while any scene is active, background only when all of them are. (A second iPad window going to the
    /// background must not cover or re-lock the one in front.)
    public private(set) var phase: AppLockPhase = .active

    public let settings: SecuritySettings
    @ObservationIgnored private let authenticator: any DeviceAuthenticating
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var leftForegroundAt: Date?
    /// The latest phase reported by each scene, keyed by the id its `AppLockGate` owns.
    @ObservationIgnored private var scenePhases: [UUID: AppLockPhase] = [:]
    /// Stands in for the scene when a caller has only one (tests, single-window apps).
    public static let defaultScene = UUID()

    /// - Parameters:
    ///   - settings: the persisted preferences; defaults to `SecuritySettings.shared`.
    ///   - authenticator: the owner-presence check; defaults to LocalAuthentication.
    ///   - now: clock, injectable for tests.
    public init(
        settings: SecuritySettings = .shared,
        authenticator: any DeviceAuthenticating = LocalAuthenticator(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.authenticator = authenticator
        self.now = now
        // Locked at launch when the user turned the lock on.
        self.isLocked = settings.appLockEnabled && authenticator.canAuthenticate
        Self.current = self
    }

    /// Face ID / Touch ID / Optic ID, or `.none` (passcode only).
    public var biometry: BiometryKind { authenticator.biometry }

    /// `true` when App Lock can be turned on on this device.
    public var isAvailable: Bool { authenticator.canAuthenticate }

    // MARK: AppLocking

    @discardableResult
    public func unlock() async -> Bool {
        guard isLocked else { return true }
        guard authenticator.canAuthenticate else {
            isLocked = false
            return true
        }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let success = await authenticator.authenticate(reason: "Unlock Tilde and your saved servers.")
        if success {
            isLocked = false
            lastAttemptFailed = false
            leftForegroundAt = nil
        } else {
            lastAttemptFailed = true
        }
        return success
    }

    public func lockNow() {
        guard authenticator.canAuthenticate else { return }
        lastAttemptFailed = false
        isLocked = true
    }

    // MARK: Settings

    /// Turns App Lock on or off. Both directions require a successful authentication first, so a borrowed,
    /// unlocked phone cannot switch the lock off. Returns the resulting state of the setting.
    @discardableResult
    public func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled != settings.appLockEnabled else { return settings.appLockEnabled }
        guard authenticator.canAuthenticate, !isAuthenticating else { return settings.appLockEnabled }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let success = await authenticator.authenticate(reason: enabled ? "Turn on App Lock." : "Turn off App Lock.")
        if success {
            settings.appLockEnabled = enabled
            if !enabled { isLocked = false }
        }
        return settings.appLockEnabled
    }

    // MARK: Scene phase

    /// Reports a life-cycle change of one scene. The scene phases are combined into `phase`; when that leaves the
    /// foreground the re-lock clock starts and, on return, the lock engages if the timeout has elapsed. Changes
    /// during the system prompt are recorded but not acted on (the prompt itself deactivates the app).
    public func sceneDidChange(_ newPhase: AppLockPhase, scene: UUID = AppLock.defaultScene) {
        scenePhases[scene] = newPhase
        guard !isAuthenticating else { return }
        apply(Self.combined(scenePhases))
    }

    /// A scene went away (its window closed): it no longer counts towards the combined phase.
    public func sceneDidDisappear(_ scene: UUID) {
        guard scenePhases.removeValue(forKey: scene) != nil, !scenePhases.isEmpty, !isAuthenticating else { return }
        apply(Self.combined(scenePhases))
    }

    static func combined(_ phases: [UUID: AppLockPhase]) -> AppLockPhase {
        let values = phases.values
        if values.contains(.active) { return .active }
        if values.contains(.inactive) { return .inactive }
        return values.isEmpty ? .active : .background
    }

    private func apply(_ newPhase: AppLockPhase) {
        phase = newPhase
        switch newPhase {
        case .background:
            if leftForegroundAt == nil { leftForegroundAt = now() }
        case .inactive:
            // On iOS `.inactive` also covers Control Center and the Face ID prompt, so only `.background` starts
            // the clock there. A Mac app that loses focus never reaches `.background`.
            #if os(macOS)
            if leftForegroundAt == nil { leftForegroundAt = now() }
            #endif
        case .active:
            defer { leftForegroundAt = nil }
            guard settings.appLockEnabled, !isLocked, let left = leftForegroundAt, authenticator.canAuthenticate else { return }
            if now().timeIntervalSince(left) >= settings.lockTimeout.seconds {
                lastAttemptFailed = false
                isLocked = true
            }
        }
    }

    /// Whether the window should be hidden behind the privacy cover right now: always while locked, and on iOS and
    /// iPadOS also whenever the app is not active (that is what the app switcher snapshots). A Mac window is not
    /// covered just because another app has focus.
    public var isPrivacyCoverVisible: Bool {
        #if os(iOS)
        isLocked || (phase != .active && settings.hideContentInSwitcher)
        #else
        isLocked
        #endif
    }
}

public extension EnvironmentValues {
    /// The app lock, injected by `AppLockGate` for everything inside it. Settings reads it to offer the toggle.
    @Entry var tildeAppLock: AppLock? = nil
}
