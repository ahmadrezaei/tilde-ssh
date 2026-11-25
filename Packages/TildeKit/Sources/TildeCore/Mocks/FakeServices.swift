import CryptoKit
import Foundation
import Observation

/// A `KeyService` that fabricates plausible-looking (but not usable) keys, so key-manager UI can be built
/// before WS3 lands. `fingerprintSHA256` is real (SHA-256 + unpadded base64).
public struct FakeKeyService: KeyService {
    public init() {}

    public func generate(_ algorithm: SSHKeyAlgorithm, bits: Int?, comment: String) async throws -> (PublicKeyInfo, PrivateKeyMaterial) {
        let blob = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let line = "\(algorithm.rawValue) \(blob.base64EncodedString()) \(comment)"
        let info = PublicKeyInfo(algorithm: algorithm, bits: algorithm == .rsa ? (bits ?? 4096) : nil,
                                 openSSH: line, fingerprintSHA256: fingerprintSHA256(publicKeyBlob: blob), comment: comment)
        return (info, PrivateKeyMaterial(algorithm: algorithm, openSSHBytes: Data("fake-private-key".utf8)))
    }

    public func parse(privateKey: Data, passphrase: String?) throws -> (PublicKeyInfo, PrivateKeyMaterial) {
        let blob = Data(privateKey.prefix(32))
        let info = PublicKeyInfo(algorithm: .ed25519, openSSH: "ssh-ed25519 \(blob.base64EncodedString()) imported",
                                 fingerprintSHA256: fingerprintSHA256(publicKeyBlob: blob), comment: "imported")
        return (info, PrivateKeyMaterial(algorithm: .ed25519, openSSHBytes: privateKey))
    }

    public func publicInfo(fromOpenSSHLine line: String) throws -> PublicKeyInfo {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let algorithm = SSHKeyAlgorithm(rawValue: parts[0]), let blob = Data(base64Encoded: parts[1]) else {
            throw KeyParseError.unsupportedFormat("not an OpenSSH public key line")
        }
        return PublicKeyInfo(algorithm: algorithm, openSSH: line, fingerprintSHA256: fingerprintSHA256(publicKeyBlob: blob),
                             comment: parts.count > 2 ? parts[2] : "")
    }

    public func fingerprintSHA256(publicKeyBlob: Data) -> String {
        let digest = Data(SHA256.hash(data: publicKeyBlob))
        var b64 = digest.base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "SHA256:" + b64
    }
}

/// Pretends every host answers in 20-120 ms (deterministic per host so previews do not flicker);
/// hosts containing "down" are unreachable.
public struct FakeReachabilityProbe: ReachabilityProbe {
    public init() {}

    public func probe(_ target: ConnectionTarget, timeout: Duration) async -> ProbeResult {
        if target.host.contains("down") { return .unreachable(reason: "Connection refused") }
        let ms = 20 + abs(target.host.hashValueStable) % 100
        return .reachable(.milliseconds(ms))
    }
}

private extension String {
    /// A stable (non-randomised) hash, unlike `hashValue`.
    var hashValueStable: Int { unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) } & 0x7FFF_FFFF }
}

/// A deliberately simple `user@host[:port]` / `ssh://user@host:port` parser. The real one (WS2) handles
/// the full grammar from section 4.4; use this only for previews.
public struct FakeQuickConnectParser: QuickConnectParsing {
    public var defaultUser: String

    public init(defaultUser: String = "root") { self.defaultUser = defaultUser }

    public func parse(_ input: String) -> QuickConnectResult? {
        var s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("ssh://") { s.removeFirst(6) }
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        var user = defaultUser
        if let at = s.lastIndex(of: "@") {
            user = String(s[..<at]); s = String(s[s.index(after: at)...])
        }
        var port = 22
        if let colon = s.lastIndex(of: ":"), let p = Int(s[s.index(after: colon)...]) {
            port = p; s = String(s[..<colon])
        }
        guard !s.isEmpty else { return nil }
        return QuickConnectResult(target: ConnectionTarget(host: s, port: port, username: user))
    }
}

/// Parses nothing, returns a fixed list: lets the import UI be previewed.
public struct FakeSSHConfigParser: SSHConfigParsing {
    public var hosts: [SSHConfigHost]

    public init(hosts: [SSHConfigHost] = [
        SSHConfigHost(alias: "prod-api", hostName: "10.0.1.12", user: "deploy", port: nil, identityFiles: ["~/.ssh/id_ed25519"], proxyJump: "bastion"),
        SSHConfigHost(alias: "bastion", hostName: "bastion.example.com", user: "ops", port: 2222),
    ]) { self.hosts = hosts }

    public func parse(_ text: String) -> [SSHConfigHost] { hosts }
}

/// An `AppLocking` that starts unlocked (or locked) and unlocks on request. For previews.
@MainActor @Observable public final class FakeAppLock: AppLocking {
    public private(set) var isLocked: Bool
    public var unlockSucceeds: Bool

    public init(isLocked: Bool = false, unlockSucceeds: Bool = true) {
        self.isLocked = isLocked
        self.unlockSucceeds = unlockSucceeds
    }

    public func unlock() async -> Bool {
        if unlockSucceeds { isLocked = false }
        return unlockSucceeds
    }

    public func lockNow() { isLocked = true }
}

public extension TildeServices {
    /// Every service backed by a mock. Used by the Phase 0 `AppEnvironment` and by SwiftUI previews.
    static var preview: TildeServices {
        TildeServices(
            secretStore: InMemorySecretStore(),
            keyService: FakeKeyService(),
            knownHosts: InMemoryKnownHostsStore(),
            credentials: FakeCredentialResolver(),
            sessionEngine: FakeSessionEngine(),
            reachability: FakeReachabilityProbe(),
            quickConnect: FakeQuickConnectParser(),
            sshConfig: FakeSSHConfigParser(),
            snippets: StaticSnippetProvider()
        )
    }
}
