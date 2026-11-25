import Foundation
import SwiftData
import TildeCore

/// Sample rows for `@Query`-driven previews. Mirrors `PreviewServers` in TildeCore.
public enum PreviewSeed {
    @MainActor
    public static func populate(_ context: ModelContext) {
        let key = SSHKeyRecord(
            name: "iphone-ed25519",
            algorithmRaw: SSHKeyAlgorithm.ed25519.rawValue,
            publicKeyOpenSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPreviewPreviewPreviewPreviewPreviewPreviewPre tilde@iphone",
            fingerprintSHA256: "SHA256:p3Kc9yFQ2nL0e1x7XvR8bq0M4aZ+u5Jd2YH6sTgVwE0",
            comment: "tilde@iphone",
            privateSecretID: PreviewServers.keyID
        )
        key.originDeviceName = "Preview Device"
        context.insert(key)

        let production = ServerGroup(name: "Production", symbol: "bolt.fill", sortIndex: 1)
        let lab = ServerGroup(name: "Homelab", symbol: "house", sortIndex: 2)
        context.insert(production)
        context.insert(lab)

        let k8s = Tag(name: "k8s"), db = Tag(name: "db"), edge = Tag(name: "edge")
        [k8s, db, edge].forEach(context.insert)

        for (index, snap) in PreviewServers.all.enumerated() {
            let server = Server(
                name: snap.name, host: snap.target.host, port: snap.target.port,
                username: snap.target.username, authMethodRaw: snap.auth.rawValue,
                environmentRaw: snap.environment.rawValue
            )
            server.id = snap.id
            server.sortIndex = Double(index)
            server.passwordSecretID = snap.passwordSecretID
            server.autoTmux = snap.autoTmux
            if snap.auth == .key { server.key = key }
            switch snap.environment {
            case .prod: server.group = production; server.isFavorite = (snap.name == "prod-api-01")
            case .lab: server.group = lab
            default: break
            }
            if snap.name == "db-primary" { server.tags = [db] }
            if snap.name == "prod-api-01" { server.tags = [k8s, edge] }
            context.insert(server)
        }
        _ = try? SnippetSeeds.seedMissing(in: context)
        try? context.save()
    }
}
