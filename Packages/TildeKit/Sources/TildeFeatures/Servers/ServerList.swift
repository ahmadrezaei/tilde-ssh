import SwiftData
import SwiftUI
import TildeDesign
import TildeStore

/// The server list. Placeholder (WS5): a flat, query-driven list. Add rows, sections, search, swipes and
/// Quick Connect here.
public struct ServerList: View {
    @Query(sort: \Server.sortIndex) private var servers: [Server]

    public init() {}

    public var body: some View {
        List(servers) { server in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(TildeFont.rowTitle).foregroundStyle(TildeColor.text)
                    Text("\(server.username)@\(server.host)").font(TildeFont.rowSubtitle).foregroundStyle(TildeColor.text2)
                }
                Spacer()
                EnvBadge(EnvTone(rawValue: server.environmentRaw) ?? .none)
            }
        }
        .navigationTitle("Servers")
        .overlay {
            if servers.isEmpty {
                ContentUnavailableView("No servers yet.", systemImage: "terminal")
            }
        }
    }
}

#Preview("ServerList") {
    NavigationStack { ServerList() }
        .modelContainer(ModelContainerFactory.preview())
}
