import SwiftUI
import TildeDesign

/// Key manager root: list, generate, import. Placeholder (WS3).
public struct KeyListView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView("No keys.", systemImage: "key", description: Text("Ed25519 takes 50 ms to generate."))
            .navigationTitle("Keys")
            .background(TildeColor.bg)
    }
}

#Preview { NavigationStack { KeyListView() } }
