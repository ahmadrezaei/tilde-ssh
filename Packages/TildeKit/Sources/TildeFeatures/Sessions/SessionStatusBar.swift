import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// What the status bar says about a session, as plain strings so the wording is testable. `SessionStatusBar` draws it.
///
/// Left: environment, `user@host:port`, `via <jump host>`, the key name or auth method. Right: latency, cipher,
/// terminal size and encoding. Latency and cipher exist only while connected; while the session is connecting,
/// reconnecting, gone or waiting for a host-key answer, `stateText` takes the latency's place.
struct SessionStatusSummary {
    let tone: EnvTone
    /// `deploy@10.0.1.12:22`. The port is always shown here (the toolbar subtitle hides 22).
    let address: String
    /// `via bastion`, when the server is reached through a jump host.
    let jump: String?
    /// The key's name, `key` for a key that is not in the store, `password` or `password prompt`.
    let auth: String
    /// `23 ms` while connected and probed.
    let latency: String?
    let latencyQuality: StatusReadout.Quality?
    let cipher: String?
    /// `126×43`, once the terminal has laid out.
    let size: String?
    let encoding = "UTF-8"
    /// `Connecting…`, `Reconnecting…`, `Disconnected`, `Connection failed` or `Verify host key`; `nil` when connected.
    let stateText: String?
    let stateQuality: StatusReadout.Quality?

    init(
        server: ServerSnapshot,
        state: SessionState,
        latencyMilliseconds: Int?,
        terminalSize: (cols: Int, rows: Int)?,
        keyName: String?,
        awaitingHostKey: Bool
    ) {
        tone = EnvTone(server.environment)
        address = "\(server.target.username)@\(server.target.host):\(server.target.port)"
        jump = server.jump.map { "via \($0.target.host)" }
        auth = Self.authLabel(server.auth, keyName: keyName)
        size = terminalSize.map { "\($0.cols)×\($0.rows)" }

        if case .connected(let info) = state {
            latency = latencyMilliseconds.map { "\($0) ms" }
            latencyQuality = latencyMilliseconds.map { StatusReadout.Quality(latencyMilliseconds: $0) }
            cipher = info.cipher
        } else {
            latency = nil
            latencyQuality = nil
            cipher = nil
        }
        (stateText, stateQuality) = Self.state(state, awaitingHostKey: awaitingHostKey)
    }

    static func authLabel(_ auth: AuthMethod, keyName: String?) -> String {
        switch auth {
        case .key: keyName ?? "key"
        case .password: "password"
        case .passwordPrompt: "password prompt"
        }
    }

    private static func state(_ state: SessionState, awaitingHostKey: Bool) -> (String?, StatusReadout.Quality?) {
        if awaitingHostKey { return ("Verify host key", .slow) }
        switch state {
        case .idle, .connecting: return ("Connecting…", .busy)
        case .reconnecting: return ("Reconnecting…", .slow)
        case .disconnected(let reason):
            if case .error = reason { return ("Connection failed", .bad) }
            return ("Disconnected", .idle)
        case .connected: return (nil, nil)
        }
    }
}

#if os(macOS)
/// The 24 pt bar at the bottom of a Mac session window: the selected tab's environment, address, jump host and key on
/// the left; latency (its only home on the Mac), cipher, terminal size and encoding on the right.
struct SessionStatusBar: View {
    let tab: SessionTab
    @Environment(SessionCoordinator.self) private var coordinator
    @Query private var keys: [SSHKeyRecord]

    var body: some View {
        let summary = SessionStatusSummary(
            server: tab.server,
            state: tab.state,
            latencyMilliseconds: tab.latencyMilliseconds,
            terminalSize: tab.terminal.size,
            keyName: tab.server.keyID.flatMap { id in keys.first { $0.privateSecretID == id }?.name },
            awaitingHostKey: coordinator.pendingInTabHostKey(for: tab.id) != nil
        )
        StatusBar {
            StatusBarEnvironmentSegment(summary.tone)
            StatusBarSegment(summary.address, help: "Connected as \(summary.address)")
            if let jump = summary.jump {
                StatusBarSegment(icon: "arrow.triangle.turn.up.right.diamond", jump, style: .label, help: "Reached through a jump host")
            }
            StatusBarSegment(icon: tab.server.auth == .key ? "key" : "lock", summary.auth, style: .label, help: "Authentication")
        } trailing: {
            if let state = summary.stateText {
                StatusBarSegment(state, style: .label, tint: tint(summary.stateQuality))
            }
            if let latency = summary.latency {
                StatusBarSegment(latency, tint: tint(summary.latencyQuality), help: "Round-trip latency")
            }
            if let cipher = summary.cipher {
                StatusBarSegment(cipher, help: "Cipher")
            }
            if let size = summary.size {
                StatusBarSegment(size, help: "Terminal size (columns × rows)")
            }
            StatusBarSegment(summary.encoding, help: "Encoding")
        }
    }

    private func tint(_ quality: StatusReadout.Quality?) -> Color? {
        switch quality {
        case .good: TildeColor.ok
        case .slow: TildeColor.warn
        case .bad: TildeColor.danger
        case .busy: TildeColor.accent
        case .idle, nil: nil
        }
    }
}
#endif
