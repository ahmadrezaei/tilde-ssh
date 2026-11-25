import Foundation

// MARK: - Reachability and parsers

public enum ProbeResult: Equatable, Sendable {
    case reachable(Duration)
    case unreachable(reason: String)
    case skipped
}

public protocol ReachabilityProbe: Sendable {
    func probe(_ target: ConnectionTarget, timeout: Duration) async -> ProbeResult
}

public struct QuickConnectResult: Equatable, Sendable {
    public var target: ConnectionTarget
    public var keyName: String?
    public var jump: ConnectionTarget?

    public init(target: ConnectionTarget, keyName: String? = nil, jump: ConnectionTarget? = nil) {
        self.target = target
        self.keyName = keyName
        self.jump = jump
    }
}

public protocol QuickConnectParsing: Sendable {
    /// Parses `user@host:port`, `ssh://...`, `ssh -p N -J jump user@host`, etc. `nil` if not a target.
    func parse(_ input: String) -> QuickConnectResult?
}

public struct SSHConfigHost: Equatable, Sendable {
    public var alias: String
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFiles: [String]
    public var proxyJump: String?

    public init(alias: String, hostName: String? = nil, user: String? = nil, port: Int? = nil, identityFiles: [String] = [], proxyJump: String? = nil) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFiles = identityFiles
        self.proxyJump = proxyJump
    }
}

public protocol SSHConfigParsing: Sendable {
    func parse(_ text: String) -> [SSHConfigHost]
}
