import SwiftUI
import TildeDesign

/// The app's root: iPhone `TabView` (Servers, Keys, Snippets, Settings) or iPad/Mac `NavigationSplitView`.
/// Placeholder (WS5): shows the server list so the app compiles and runs end-to-end.
public struct RootView: View {
    public init() {}

    public var body: some View {
        NavigationStack { ServerList() }
            .background(TildeColor.bg)
    }
}

#Preview { RootView() }
