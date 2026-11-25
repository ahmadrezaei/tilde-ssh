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
        seedKnownHosts(context)
        _ = try? SnippetSeeds.seedMissing(in: context)
        try? context.save()
    }

    /// Demo pins for the Known Hosts screen. The fingerprints are made-up values, not real keys.
    @MainActor
    private static func seedKnownHosts(_ context: ModelContext) {
        let day: TimeInterval = 24 * 60 * 60
        let pins: [(endpoint: String, algorithm: String, fingerprint: String, device: String, firstSeenDaysAgo: Double, status: KnownHostStatus)] = [
            ("10.0.1.12", "ssh-ed25519", "SHA256:p3Kc9yFQ2nL0e1x7XvR8bq0M4aZ+u5Jd2YH6sTgVwE0", "iPhone", 41, .trusted),
            ("10.0.1.12", "ecdsa-sha2-nistp256", "SHA256:Hq7uY1m0Zr3bN8cVd4Ls9WfKxT2eA6pGjR5oUiBvC1k", "iPhone", 41, .trusted),
            ("10.0.2.5", "ssh-ed25519", "SHA256:Zt4eR9vB2xW7kLq0NcY5mUa8Jd1HsGfP3oTiVbE6wXn", "MacBook Pro", 18, .trusted),
            ("pi.local", "ssh-ed25519", "SHA256:Wn2xK8dQ5vLr1BcYt7Ua0MfJe4HsGpZ9oTiVbE3gRkA", "MacBook Pro", 9, .trusted),
            ("[staging.example.com]:2222", "ssh-ed25519", "SHA256:Lc8aN3vB6xW1kQr5ZtY0mUe7Jd2HsGfP4oTiVbR9wXn", "iPad", 3, .conflicted),
        ]
        for pin in pins {
            let host = KnownHost(endpoint: pin.endpoint, algorithm: pin.algorithm, publicKeyBase64: "AAAAPreview", fingerprintSHA256: pin.fingerprint, trustedOnDevice: pin.device)
            host.firstSeenAt = Date.now.addingTimeInterval(-pin.firstSeenDaysAgo * day)
            host.lastSeenAt = Date.now.addingTimeInterval(-min(pin.firstSeenDaysAgo, 2) * day)
            host.status = pin.status
            context.insert(host)
        }
    }
}
