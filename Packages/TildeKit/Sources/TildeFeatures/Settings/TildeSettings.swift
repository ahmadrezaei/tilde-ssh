import Foundation
import SwiftUI

/// UserDefaults / `@AppStorage` keys and enums for the settings owned by the app shell.
///
/// Interim storage: once `Preferences` (WS1, `NSUbiquitousKeyValueStore` + `UserDefaults`) lands, these keys move
/// behind it. Views read them through `@AppStorage`, so the switch is local to this file and `SettingsRoot`.
public enum TildeSettings {
    public static let appearanceKey = "settings.appearance"
    public static let confirmPasteKey = "settings.confirmMultilinePaste"
    public static let serverSortKey = "settings.serverSort"
    public static let showOfflineKey = "settings.showOfflineServers"
    public static let defaultUserKey = "settings.defaultUsername"
    public static let defaultKeyKey = "settings.defaultKeyID"
    public static let connectTimeoutKey = "settings.connectTimeoutSeconds"
    public static let autoReconnectKey = "settings.autoReconnect"
    public static let probeReachabilityKey = "settings.probeReachability"
    public static let probeOnCellularKey = "settings.probeOnCellular"
    public static let scrollbackKey = "settings.scrollbackLines"
    public static let defaultTermKey = "settings.defaultTerm"
    public static let defaultKeepAliveKey = "settings.defaultKeepAlive"
    public static let onboardingDoneKey = "onboarding.done"
    public static let collapsedSectionsKey = "serverList.collapsed"

    public static let defaultUser = "root"
    public static let defaultConnectTimeout = 15
    public static let defaultTerm = "xterm-256color"
    public static let defaultKeepAlive = 30
    public static let defaultScrollback = 10_000

    /// The stored default username, falling back to `root`.
    public static var currentDefaultUser: String {
        let value = UserDefaults.standard.string(forKey: defaultUserKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? defaultUser : value
    }

    /// The stored connect timeout (seconds), 15 by default.
    public static var currentConnectTimeout: Int {
        let value = UserDefaults.standard.integer(forKey: connectTimeoutKey)
        return value > 0 ? value : defaultConnectTimeout
    }

    public static var currentPasteMode: PasteConfirmMode {
        PasteConfirmMode(rawValue: UserDefaults.standard.string(forKey: confirmPasteKey) ?? "") ?? .prodOnly
    }

    public static var currentServerSort: ServerSortMode {
        ServerSortMode(rawValue: UserDefaults.standard.string(forKey: serverSortKey) ?? "") ?? .manual
    }
}

/// App appearance. Dark is the default regardless of the system setting (docs/DESIGN.md section 2.2).
public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case dark, system, light

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dark: "Dark"
        case .system: "Match System"
        case .light: "Light"
        }
    }

    /// `nil` follows the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .system: nil
        case .light: .light
        }
    }

    public static func from(rawValue: String) -> AppAppearance { AppAppearance(rawValue: rawValue) ?? .dark }
}

/// Settings > Terminal > Confirm multi-line paste.
public enum PasteConfirmMode: String, CaseIterable, Identifiable, Sendable {
    case prodOnly, always, never

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .prodOnly: "Production only"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

/// How the server list orders servers inside a group.
public enum ServerSortMode: String, CaseIterable, Identifiable, Sendable {
    case manual, name, lastUsed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .lastUsed: "Last used"
        }
    }

    public var systemImage: String {
        switch self {
        case .manual: "hand.draw"
        case .name: "textformat"
        case .lastUsed: "clock"
        }
    }
}
