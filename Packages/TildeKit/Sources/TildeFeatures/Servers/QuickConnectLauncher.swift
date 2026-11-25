import Foundation
import SwiftData
import TildeCore
import TildeStore

/// Parses Quick Connect input, resolves auth (saved server, default key, password prompt), records the recent, and
/// opens the session. Used by the server list, the command palette, the toolbar field and `ssh://` links.
@MainActor
struct QuickConnectLauncher {
    let services: TildeServices
    let context: ModelContext
    let navigator: AppNavigator

    /// Parses `input` with the engine's parser. Fills in the default username when the input has none.
    func parse(_ input: String) -> QuickConnectResult? {
        guard var result = services.quickConnect.parse(input) else { return nil }
        if result.target.username.isEmpty { result.target.username = TildeSettings.currentDefaultUser }
        return result
    }

    /// Opens the session. Returns `nil` if `input` is not a connection target.
    @discardableResult
    func connect(_ input: String) -> SessionTab? {
        guard let result = parse(input) else { return nil }
        return connect(result)
    }

    @discardableResult
    func connect(_ result: QuickConnectResult) -> SessionTab {
        let servers = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        let keys = (try? context.fetch(FetchDescriptor<SSHKeyRecord>())) ?? []
        let resolution = QuickConnectResolver.resolve(
            result,
            saved: servers.map(ServerMapper.snapshot),
            keys: keys.map { QuickConnectKey(name: $0.name, secretID: $0.privateSecretID, recordID: $0.id) },
            defaultKeyRecordID: UserDefaults.standard.string(forKey: TildeSettings.defaultKeyKey).flatMap(UUID.init(uuidString:))
        )
        let savedServer = resolution.isSaved ? servers.first { $0.id == resolution.server.id } : nil
        ServerActions(context: context, secrets: services.secretStore).recordRecent(result.target, server: savedServer)
        return navigator.open(resolution.server, adHoc: !resolution.isSaved)
    }

    /// Opens the session for a link the user confirmed: a new tab with a password prompt (see
    /// `QuickConnectResolver.linkServer`).
    @discardableResult
    func connectFromLink(_ result: QuickConnectResult) -> SessionTab {
        navigator.open(QuickConnectResolver.linkServer(result), newSession: true, adHoc: true)
    }

    /// Opens a saved server: focuses its session, or starts one (`newSession` forces a new tab).
    @discardableResult
    func open(_ server: Server, newSession: Bool = false) -> SessionTab {
        navigator.open(ServerMapper.snapshot(server), newSession: newSession)
    }
}
