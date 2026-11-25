import SwiftUI

/// The Mac (and iPadOS 26) menu bar: File, Edit, View, Session, Window (docs/DESIGN.md section 3.4).
/// Placeholder (WS6): wire to `SessionCoordinator` through `FocusedValues` once WS5 publishes them.
public struct MacCommands: Commands {
    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {}.keyboardShortcut("t")
            Button("Quick Connect") {}.keyboardShortcut("l")
        }
    }
}
