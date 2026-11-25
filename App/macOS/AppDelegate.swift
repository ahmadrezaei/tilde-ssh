import AppKit
import TildeFeatures

/// macOS app glue (docs/DESIGN.md section 3.4).
///
/// SwiftUI owns the scenes and menus. This delegate covers what SwiftUI does not:
/// - Keeps tabs in-window: native NSWindow tabbing would duplicate the sidebar per tab.
/// - Closing the last window leaves the app running, like Terminal and iTerm2, and clicking the Dock icon
///   brings a window back.
/// - Holds secure keyboard entry only while Tilde is the active app.
///
/// `ssh://` and `tilde://` links are delivered to `.onOpenURL` in `TildeApp` (the delegate deliberately does not
/// implement `application(_:open:)`, which would stop SwiftUI from delivering them). Parse them with
/// `TildeURLParser`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            SecureKeyboardEntry.shared.install()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            SecureKeyboardEntry.shared.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Returning `true` lets SwiftUI open a new main window when the Dock icon is clicked with none visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
