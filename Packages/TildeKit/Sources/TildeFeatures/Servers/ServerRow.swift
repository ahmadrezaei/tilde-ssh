import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// One server row (design section 4.1): status dot, mono name, `user@host:port` + auth glyph, env badge, latency.
struct ServerRow: View {
    let server: Server
    let isLive: Bool
    let status: ReachabilityMonitor.Status

    var body: some View {
        HStack(spacing: TildeSpacing.m) {
            StatusDot(dotKind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(ServerMapper.displayName(server))
                        .tildeMono(15, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(TildeColor.text)
                        .lineLimit(1)
                    if server.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(TildeColor.warn).accessibilityLabel("Favorite")
                    }
                }
                HStack(spacing: 5) {
                    Text(subtitle).tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.text2).lineLimit(1)
                    Image(systemName: authSymbol).font(.system(size: 9)).foregroundStyle(TildeColor.text3).accessibilityHidden(true)
                }
            }
            Spacer(minLength: TildeSpacing.s)
            EnvBadge(EnvTone(ServerMapper.environment(server)))
            if let ms = status.latencyMilliseconds {
                Text("\(ms)ms")
                    .tildeMono(11, relativeTo: .caption)
                    .foregroundStyle(StatusDot.Kind(latencyMilliseconds: ms) == .slow ? TildeColor.warn : TildeColor.text3)
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .tildeRowHeight()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var subtitle: String {
        let base = "\(server.username)@\(server.host)"
        return server.port == 22 ? base : "\(base):\(server.port)"
    }

    private var authSymbol: String {
        switch ServerMapper.authMethod(server) {
        case .key: "key.fill"
        case .password, .passwordPrompt: "ellipsis"
        }
    }

    private var dotKind: StatusDot.Kind {
        if isLive { return .live }
        switch status {
        case .unknown, .probing: return .unknown
        case .reachable(let ms): return StatusDot.Kind(latencyMilliseconds: ms)
        case .unreachable: return .unreachable
        }
    }

    private var accessibilityLabel: String {
        var parts = [ServerMapper.displayName(server), subtitle]
        let env = EnvTone(ServerMapper.environment(server))
        if env != .none { parts.append(env.accessibilityName) }
        if isLive { parts.append("session open") }
        else if let ms = status.latencyMilliseconds { parts.append("reachable, \(ms) milliseconds") }
        else if case .unreachable = status { parts.append("unreachable") }
        return parts.joined(separator: ", ")
    }
}

/// A row in the LIVE section: an open session.
struct LiveSessionRow: View {
    let tab: SessionTab

    var body: some View {
        HStack(spacing: TildeSpacing.m) {
            StatusDot(tab.isConnected ? .live : tab.statusKind)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).tildeMono(15, weight: .semibold, relativeTo: .body).foregroundStyle(TildeColor.text).lineLimit(1)
                Text(stateText).tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.text2).lineLimit(1)
            }
            Spacer(minLength: TildeSpacing.s)
            EnvBadge(tab.tone)
            if let ms = tab.latencyMilliseconds {
                Text("\(ms)ms").tildeMono(11, relativeTo: .caption).foregroundStyle(TildeColor.text3)
            }
        }
        .tildeRowHeight()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tab.title), \(stateText), open session")
    }

    private var stateText: String {
        switch tab.state {
        case .idle, .connecting: "connecting…"
        case .connected: tab.server.target.displayString
        case .reconnecting: "reconnecting…"
        case .disconnected: "disconnected"
        }
    }
}

/// `↵ Connect to deploy@10.0.4.12:2222`, shown first when the search text parses as a target.
struct ConnectToRow: View {
    let target: ConnectionTarget

    var body: some View {
        HStack(spacing: TildeSpacing.s) {
            Image(systemName: "return").font(.system(size: 13, weight: .bold)).accessibilityHidden(true)
            Text("Connect to \(Text(target.displayString).foregroundStyle(TildeColor.accent).fontWeight(.semibold))")
                .foregroundStyle(TildeColor.text2)
            Spacer(minLength: 0)
        }
        .tildeMono(13, relativeTo: .subheadline)
        .foregroundStyle(TildeColor.accent)
        .tildeRowHeight()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connect to \(target.displayString)")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview("ServerRow") {
    let keyServer = Server(name: "prod-api-01", host: "10.0.1.12", port: 22, username: "deploy", environmentRaw: "prod")
    let pwServer = Server(name: "staging-web", host: "staging.example.com", port: 2222, username: "deploy", authMethodRaw: "password", environmentRaw: "staging")
    return List {
        ServerRow(server: keyServer, isLive: true, status: .reachable(milliseconds: 23))
        ServerRow(server: pwServer, isLive: false, status: .reachable(milliseconds: 212))
        ServerRow(server: pwServer, isLive: false, status: .unreachable(reason: "refused"))
        ConnectToRow(target: ConnectionTarget(host: "10.0.4.12", port: 2222, username: "deploy"))
    }
    .tildeList()
    .preferredColorScheme(.dark)
}
