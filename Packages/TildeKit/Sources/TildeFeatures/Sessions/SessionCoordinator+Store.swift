import Foundation
import SwiftData
import TildeStore

public extension SessionCoordinator {
    /// Stores `Server.lastConnectedAt` whenever a session connects (throttled to once per 5 minutes per server, since it
    /// syncs). Call once from the app environment with the main context.
    func recordConnections(in context: ModelContext) {
        let secrets = services.secretStore
        onConnected = { snapshot in
            ServerActions(context: context, secrets: secrets).touchConnected(serverID: snapshot.id)
        }
    }
}
