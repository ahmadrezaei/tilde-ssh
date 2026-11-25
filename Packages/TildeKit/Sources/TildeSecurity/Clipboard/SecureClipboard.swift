import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Pasteboard helpers. Copying a **secret** (a private key, a password) expires the clipboard entry after the
/// time set in Settings > Security (60 s by default), keeps it off Universal Clipboard and, on the Mac, marks
/// it as concealed so clipboard managers skip it. Public keys use `copy(_:)`.
@MainActor
public enum SecureClipboard {
    private static var pendingClear: Task<Void, Never>?

    /// Copies non-secret text (public key, fingerprint).
    public static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Copies a secret and removes it again after `seconds` (`nil`: the user's setting; 0: never).
    public static func copySecret(_ text: String, clearAfter seconds: Int? = nil) {
        let delay = seconds ?? SecuritySettings.shared.clipboardClearSeconds
        pendingClear?.cancel()
        pendingClear = nil
        #if canImport(UIKit)
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if delay > 0 { options[.expirationDate] = Date(timeIntervalSinceNow: TimeInterval(delay)) }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: text]], options: options)
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealed)
        if delay > 0 {
            let expectedChangeCount = pasteboard.changeCount
            pendingClear = Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                // Only clear our own entry; never wipe something the user copied in the meantime.
                if !Task.isCancelled, NSPasteboard.general.changeCount == expectedChangeCount {
                    NSPasteboard.general.clearContents()
                }
            }
        }
        #endif
    }

    /// The pasteboard's text, for "Paste from clipboard" in the import flow.
    public static func currentString() -> String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #elseif canImport(AppKit)
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}
