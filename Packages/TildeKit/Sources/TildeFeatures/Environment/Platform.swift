import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Small platform shims. Everything else in the feature views is shared SwiftUI.
enum Platform {
    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Copies plain text (fingerprints, SSH commands, public keys). For secrets, use the expiring clipboard.
    @MainActor
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    /// The device name, for default key names and "trusted on" captions.
    @MainActor
    static var deviceName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Light haptic for confirmations. No-op on Mac.
    @MainActor
    static func haptic(_ style: HapticStyle) {
        #if canImport(UIKit)
        switch style {
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        }
        #endif
    }

    enum HapticStyle { case success, warning, selection }
}
