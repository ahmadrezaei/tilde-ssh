import Foundation

// MARK: - Value types
//
// Sendable snapshots that cross actor and module boundaries. These are never `@Model`
// classes: SwiftData objects stay inside `TildeStore` and are mapped to snapshots at the edge.

/// The environment a server belongs to. Drives the PROD/STG/DEV/LAB colour system.
public enum ServerEnvironment: String, Codable, Sendable, CaseIterable {
    case none, dev, staging, prod, lab
}

/// How a server authenticates. Raw values match `Server.authMethodRaw` in the store.
public enum AuthMethod: String, Codable, Sendable {
    /// Public-key auth; the private key is referenced by `keyID`.
    case key
    /// Saved password; the secret is referenced by `passwordSecretID`.
    case password
    /// Ask for the password on every connection (nothing is stored).
    case passwordPrompt
}

/// Where to connect. Built from Quick Connect input or from a saved server.
public struct ConnectionTarget: Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}

/// An immutable, Sendable copy of a saved (or ad-hoc) server, handed to the SSH engine and the UI.
public struct ServerSnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var target: ConnectionTarget
    public var auth: AuthMethod
    public var keyID: UUID?
    public var passwordSecretID: UUID?
    public var environment: ServerEnvironment
    /// One hop at MVP.
    public var jump: JumpSnapshot?
    public var startupCommand: String?
    public var autoTmux: Bool
    public var tmuxSessionName: String
    /// 0 disables keep-alive.
    public var keepAliveSeconds: Int
    public var termType: String
    public var envVars: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        target: ConnectionTarget,
        auth: AuthMethod = .key,
        keyID: UUID? = nil,
        passwordSecretID: UUID? = nil,
        environment: ServerEnvironment = .none,
        jump: JumpSnapshot? = nil,
        startupCommand: String? = nil,
        autoTmux: Bool = false,
        tmuxSessionName: String = "tilde",
        keepAliveSeconds: Int = 30,
        termType: String = "xterm-256color",
        envVars: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.target = target
        self.auth = auth
        self.keyID = keyID
        self.passwordSecretID = passwordSecretID
        self.environment = environment
        self.jump = jump
        self.startupCommand = startupCommand
        self.autoTmux = autoTmux
        self.tmuxSessionName = tmuxSessionName
        self.keepAliveSeconds = keepAliveSeconds
        self.termType = termType
        self.envVars = envVars
    }
}

/// The bastion a server is reached through (ProxyJump, a single hop at MVP).
public struct JumpSnapshot: Hashable, Sendable {
    public var target: ConnectionTarget
    public var auth: AuthMethod
    public var keyID: UUID?
    public var passwordSecretID: UUID?

    public init(target: ConnectionTarget, auth: AuthMethod = .key, keyID: UUID? = nil, passwordSecretID: UUID? = nil) {
        self.target = target
        self.auth = auth
        self.keyID = keyID
        self.passwordSecretID = passwordSecretID
    }
}
