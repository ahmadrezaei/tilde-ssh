import SwiftUI
import TildeDesign

/// Settings > Keyboard > Key bar: live preview, pages, slots, presets. Placeholder: WS4 replaces the body.
public struct KeyBarEditorView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView("Key bar editor", systemImage: "keyboard", description: Text("Coming from the terminal workstream."))
            .background(TildeColor.bg)
    }
}

#Preview { KeyBarEditorView() }
