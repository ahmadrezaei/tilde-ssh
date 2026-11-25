import Foundation

/// Fixed sample data for SwiftUI previews, tests and the mock `AppEnvironment`.
/// UUIDs are stable so previews and snapshot tests are deterministic.
public enum PreviewServers {
    public static let keyID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    public static let passwordSecretID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!

    public static let bastion = ServerSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "bastion",
        target: ConnectionTarget(host: "bastion.example.com", username: "ops"),
        auth: .key, keyID: keyID,
        environment: .none
    )

    public static let prodAPI = ServerSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "prod-api-01",
        target: ConnectionTarget(host: "10.0.1.12", username: "deploy"),
        auth: .key, keyID: keyID,
        environment: .prod,
        jump: JumpSnapshot(target: bastion.target, auth: .key, keyID: keyID),
        autoTmux: true
    )

    public static let dbPrimary = ServerSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "db-primary",
        target: ConnectionTarget(host: "10.0.2.5", username: "postgres"),
        auth: .key, keyID: keyID,
        environment: .prod
    )

    public static let stagingWeb = ServerSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        name: "staging-web",
        target: ConnectionTarget(host: "staging.example.com", port: 2222, username: "deploy"),
        auth: .password, passwordSecretID: passwordSecretID,
        environment: .staging
    )

    public static let devBox = ServerSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        name: "dev-sandbox",
        target: ConnectionTarget(host: "dev.example.com", username: "dev"),
        auth: .passwordPrompt,
        environment: .dev
    )

    public static let homelab = ServerSnapshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
        name: "homelab-pi",
        target: ConnectionTarget(host: "pi.local", username: "pi"),
        auth: .key, keyID: keyID,
        environment: .lab,
        keepAliveSeconds: 0
    )

    /// All samples, in a plausible list order.
    public static let all: [ServerSnapshot] = [prodAPI, dbPrimary, stagingWeb, devBox, homelab, bastion]
}
