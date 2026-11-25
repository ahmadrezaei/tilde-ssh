import SwiftUI
import TildeCore
import TildeDesign
import TildeTerminal

/// iPad/Mac detail column: tab strip plus `TerminalSurface`. Placeholder (WS5): shows one mock session.
/// The real one is driven by `SessionCoordinator` (`@Observable`, owns sessions and tabs).
public struct SessionContainer: View {
    @Environment(\.tildeServices) private var services
    @State private var session: any TerminalSession = EchoTerminalSession(server: PreviewServers.prodAPI)

    public init() {}

    public var body: some View {
        TerminalSurface(
            io: session,
            environment: session.server.environment,
            snippets: services.snippets
        )
    }
}

#Preview { SessionContainer() }
