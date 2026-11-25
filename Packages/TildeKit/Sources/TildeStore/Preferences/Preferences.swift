import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

// MARK: - Backing stores

/// The minimal key-value interface `Preferences` needs. `UserDefaults` and `NSUbiquitousKeyValueStore`
/// conform; tests and previews use `InMemoryPreferenceBacking`.
public protocol PreferenceBacking: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: PreferenceBacking {}
extension NSUbiquitousKeyValueStore: PreferenceBacking {}

/// A dictionary-backed store for tests and previews.
public final class InMemoryPreferenceBacking: PreferenceBacking {
    private var values: [String: Any] = [:]

    public init() {}

    public func object(forKey key: String) -> Any? { values[key] }
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
    public func removeObject(forKey key: String) { values[key] = nil }
}

// MARK: - Value types

/// Settings > Appearance > App appearance.
public enum AppAppearance: String, CaseIterable, Sendable { case dark, system, light }

/// Settings > Appearance > Font.
public enum TerminalFontChoice: String, CaseIterable, Sendable { case sfMono, jetBrainsMono, menlo }

/// Settings > Appearance > Cursor.
public enum CursorStyle: String, CaseIterable, Sendable { case block, bar, underline }

/// Settings > Appearance > Bell.
public enum BellMode: String, CaseIterable, Sendable { case haptic, visual, off }

/// Settings > Terminal > Confirm multi-line paste.
public enum PasteConfirmation: String, CaseIterable, Sendable { case prodOnly, always, never }

/// Settings > Security > App Lock. `off` disables the lock; the others are the re-lock delay.
public enum AppLockTimeout: String, CaseIterable, Sendable {
    case off, immediately, oneMinute, fiveMinutes, fifteenMinutes

    /// The delay before re-locking, or `nil` when the lock is off.
    public var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .immediately: 0
        case .oneMinute: 60
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        }
    }
}

// MARK: - Preferences

/// App preferences, `@Observable` for SwiftUI.
///
/// Two scopes (docs/DESIGN.md section 6.1):
/// - **Synced** values live in `NSUbiquitousKeyValueStore` (1 MB budget): look and feel, defaults for new
///   servers, security and terminal behaviour. They follow the user across devices.
/// - **Local** values live in `UserDefaults`: things that differ per screen or per device (terminal font size,
///   hardware-keyboard mode, the sync switch itself, onboarding state).
///
/// Every property has a default, ignores out-of-range or unknown stored values, and clamps numbers, so a value
/// written by a newer app version never breaks an older one. Changes made on another device arrive through
/// `NSUbiquitousKeyValueStore.didChangeExternallyNotification` and invalidate observers automatically.
@MainActor
@Observable
public final class Preferences {
    @ObservationIgnored private let synced: any PreferenceBacking
    @ObservationIgnored private let local: any PreferenceBacking
    @ObservationIgnored private var externalObserver: (any NSObjectProtocol)?

    /// Bumped on every write and on every external change; every getter reads it, so views re-render.
    private var revision = 0

    public init(synced: any PreferenceBacking, local: any PreferenceBacking) {
        self.synced = synced
        self.local = local
        if let store = synced as? NSUbiquitousKeyValueStore {
            externalObserver = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
            store.synchronize()
        }
    }

    isolated deinit {
        if let externalObserver { NotificationCenter.default.removeObserver(externalObserver) }
    }

    /// The production instance: iCloud key-value store for synced values, standard `UserDefaults` for local ones.
    public static func live() -> Preferences {
        Preferences(synced: NSUbiquitousKeyValueStore.default, local: UserDefaults.standard)
    }

    /// An isolated instance for tests and previews.
    public static func inMemory() -> Preferences {
        Preferences(synced: InMemoryPreferenceBacking(), local: InMemoryPreferenceBacking())
    }

    /// Re-reads everything (call after an external change you observed yourself).
    public func reload() { revision &+= 1 }

    // MARK: Keys

    /// Storage keys. Raw values are persisted (and synced), so they never change.
    public enum Key: String, CaseIterable, Sendable {
        // Synced
        case appearance = "pref.appearance"
        case terminalTheme = "pref.terminalTheme"
        case fontFamily = "pref.fontFamily"
        case cursorStyle = "pref.cursorStyle"
        case cursorBlink = "pref.cursorBlink"
        case bellMode = "pref.bellMode"
        case keyBarLayout = "pref.keyBarLayout"
        case hapticsEnabled = "pref.haptics"
        case optionAsMeta = "pref.optionAsMeta"
        case commandPeriodSendsEscape = "pref.cmdPeriodEsc"
        case scrollbackLines = "pref.scrollbackLines"
        case pasteConfirmation = "pref.pasteConfirmation"
        case copyOnSelect = "pref.copyOnSelect"
        case defaultTermType = "pref.defaultTerm"
        case defaultKeepAliveSeconds = "pref.defaultKeepAlive"
        case defaultUsername = "pref.defaultUser"
        case defaultKeyID = "pref.defaultKeyID"
        case connectTimeoutSeconds = "pref.connectTimeout"
        case autoReconnect = "pref.autoReconnect"
        case probeReachability = "pref.probeReachability"
        case probeOnCellular = "pref.probeOnCellular"
        case appLockTimeout = "pref.appLockTimeout"
        case hideContentInAppSwitcher = "pref.hideInSwitcher"
        case strictHostChecking = "pref.strictHostChecking"
        case clipboardClearSeconds = "pref.clipboardClear"
        // Local
        case terminalFontSize = "local.terminalFontSize"
        case hardwareKeyboardMode = "local.hardwareKeyboardMode"
        case syncEnabled = "local.syncEnabled"
        case hasCompletedOnboarding = "local.onboardingDone"

        /// Synced through iCloud KVS (`true`) or kept on this device (`false`).
        public var isSynced: Bool { !rawValue.hasPrefix("local.") }
    }

    // MARK: Synced: appearance

    /// App appearance. Default: dark, regardless of the system setting.
    public var appearance: AppAppearance {
        get { enumValue(.appearance, default: .dark) }
        set { write(newValue.rawValue, .appearance) }
    }

    /// The terminal theme's name (`TerminalTheme` is owned by the terminal module). Default "Tilde Night".
    public var terminalTheme: String {
        get { string(.terminalTheme, default: "Tilde Night") }
        set { write(newValue, .terminalTheme) }
    }

    public var fontFamily: TerminalFontChoice {
        get { enumValue(.fontFamily, default: .sfMono) }
        set { write(newValue.rawValue, .fontFamily) }
    }

    public var cursorStyle: CursorStyle {
        get { enumValue(.cursorStyle, default: .block) }
        set { write(newValue.rawValue, .cursorStyle) }
    }

    /// Cursor blinking. Default off (calmer at 3am).
    public var cursorBlink: Bool {
        get { bool(.cursorBlink, default: false) }
        set { write(newValue, .cursorBlink) }
    }

    public var bellMode: BellMode {
        get { enumValue(.bellMode, default: .haptic) }
        set { write(newValue.rawValue, .bellMode) }
    }

    // MARK: Synced: keyboard

    /// The key bar layout as JSON, written and read by the terminal module (`KeyBarLayout`). `nil` = default layout.
    public var keyBarLayoutData: Data? {
        get { data(.keyBarLayout) }
        set { write(newValue, .keyBarLayout) }
    }

    public var hapticsEnabled: Bool {
        get { bool(.hapticsEnabled, default: true) }
        set { write(newValue, .hapticsEnabled) }
    }

    /// Option acts as Meta (hardware keyboard).
    public var optionAsMeta: Bool {
        get { bool(.optionAsMeta, default: true) }
        set { write(newValue, .optionAsMeta) }
    }

    /// Command-period sends Esc.
    public var commandPeriodSendsEscape: Bool {
        get { bool(.commandPeriodSendsEscape, default: true) }
        set { write(newValue, .commandPeriodSendsEscape) }
    }

    // MARK: Synced: terminal

    /// Scrollback lines, 1 000 to 100 000. Default 10 000.
    public var scrollbackLines: Int {
        get { int(.scrollbackLines, default: 10_000, in: 1_000...100_000) }
        set { write(min(max(newValue, 1_000), 100_000), .scrollbackLines) }
    }

    public var pasteConfirmation: PasteConfirmation {
        get { enumValue(.pasteConfirmation, default: .prodOnly) }
        set { write(newValue.rawValue, .pasteConfirmation) }
    }

    /// Copy on select (Mac).
    public var copyOnSelect: Bool {
        get { bool(.copyOnSelect, default: false) }
        set { write(newValue, .copyOnSelect) }
    }

    public var defaultTermType: String {
        get { string(.defaultTermType, default: "xterm-256color") }
        set { write(newValue.nilIfBlank ?? "xterm-256color", .defaultTermType) }
    }

    /// Keep-alive for new servers, seconds (0 = off).
    public var defaultKeepAliveSeconds: Int {
        get { int(.defaultKeepAliveSeconds, default: 30, in: 0...600) }
        set { write(min(max(newValue, 0), 600), .defaultKeepAliveSeconds) }
    }

    // MARK: Synced: connections

    /// Username pre-filled for new servers.
    public var defaultUsername: String {
        get { string(.defaultUsername, default: "root") }
        set { write(newValue, .defaultUsername) }
    }

    /// The key used by Quick Connect and pre-selected for new servers (`SSHKeyRecord.id`).
    public var defaultKeyID: UUID? {
        get { UUID(uuidString: string(.defaultKeyID, default: "")) }
        set { write(newValue?.uuidString, .defaultKeyID) }
    }

    /// Connect timeout, seconds, 5 to 120. Default 15.
    public var connectTimeoutSeconds: Int {
        get { int(.connectTimeoutSeconds, default: 15, in: 5...120) }
        set { write(min(max(newValue, 5), 120), .connectTimeoutSeconds) }
    }

    public var autoReconnect: Bool {
        get { bool(.autoReconnect, default: true) }
        set { write(newValue, .autoReconnect) }
    }

    public var probeReachability: Bool {
        get { bool(.probeReachability, default: true) }
        set { write(newValue, .probeReachability) }
    }

    /// Probe reachability on cellular too. Default off.
    public var probeOnCellular: Bool {
        get { bool(.probeOnCellular, default: false) }
        set { write(newValue, .probeOnCellular) }
    }

    // MARK: Synced: security

    /// App Lock setting. Default `.off`; an unrecognised stored value reads as `.immediately`.
    public var appLockTimeout: AppLockTimeout {
        get {
            // Fail closed: nothing stored means the lock was never turned on, but a value this version does not
            // recognise (written by a newer app) must not silently disable the lock.
            guard let stored = raw(.appLockTimeout) as? String else { return .off }
            return AppLockTimeout(rawValue: stored) ?? .immediately
        }
        set { write(newValue.rawValue, .appLockTimeout) }
    }

    /// Cover the app in the app switcher. Default on.
    public var hideContentInAppSwitcher: Bool {
        get { bool(.hideContentInAppSwitcher, default: true) }
        set { write(newValue, .hideContentInAppSwitcher) }
    }

    /// Refuse unknown hosts (no TOFU). Default off.
    public var strictHostChecking: Bool {
        get { bool(.strictHostChecking, default: false) }
        set { write(newValue, .strictHostChecking) }
    }

    /// Seconds before a copied secret is cleared from the clipboard (0 = never), up to an hour. Default 60.
    public var clipboardClearSeconds: Int {
        get { int(.clipboardClearSeconds, default: 60, in: 0...3_600) }
        set { write(min(max(newValue, 0), 3_600), .clipboardClearSeconds) }
    }

    // MARK: Local (per device)

    /// Terminal font size in points, at least 9. Default 12 on iPhone, 13 on iPad and Mac. Not synced: screens differ.
    public var terminalFontSize: Double {
        get {
            access(keyPath: \.revision)
            let stored = (local.object(forKey: Key.terminalFontSize.rawValue) as? NSNumber)?.doubleValue
            return min(max(stored ?? Self.platformDefaultFontSize, 9), 40)
        }
        set { write(min(max(newValue, 9), 40), .terminalFontSize) }
    }

    /// `HardwareKeyboardMode` raw value (`slimStrip` / `hidden`); the terminal module owns the enum.
    public var hardwareKeyboardModeRaw: String {
        get { string(.hardwareKeyboardMode, default: "slimStrip") }
        set { write(newValue, .hardwareKeyboardMode) }
    }

    /// The "Sync on/off" switch. A per-device choice, because it decides how the container is created at launch.
    public var syncEnabled: Bool {
        get { bool(.syncEnabled, default: true) }
        set { write(newValue, .syncEnabled) }
    }

    public var hasCompletedOnboarding: Bool {
        get { bool(.hasCompletedOnboarding, default: false) }
        set { write(newValue, .hasCompletedOnboarding) }
    }

    // MARK: Plumbing

    static var platformDefaultFontSize: Double {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? 13 : 12
        #else
        13
        #endif
    }

    private func store(for key: Key) -> any PreferenceBacking { key.isSynced ? synced : local }

    private func raw(_ key: Key) -> Any? {
        access(keyPath: \.revision)
        return store(for: key).object(forKey: key.rawValue)
    }

    private func bool(_ key: Key, default fallback: Bool) -> Bool {
        (raw(key) as? NSNumber)?.boolValue ?? fallback
    }

    private func int(_ key: Key, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        guard let stored = (raw(key) as? NSNumber)?.intValue else { return fallback }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    private func string(_ key: Key, default fallback: String) -> String {
        (raw(key) as? String) ?? fallback
    }

    private func data(_ key: Key) -> Data? { raw(key) as? Data }

    private func enumValue<Value: RawRepresentable>(_ key: Key, default fallback: Value) -> Value where Value.RawValue == String {
        guard let stored = raw(key) as? String, let value = Value(rawValue: stored) else { return fallback }
        return value
    }

    private func write(_ value: Any?, _ key: Key) {
        if let value { store(for: key).set(value, forKey: key.rawValue) } else { store(for: key).removeObject(forKey: key.rawValue) }
        revision &+= 1
    }
}
