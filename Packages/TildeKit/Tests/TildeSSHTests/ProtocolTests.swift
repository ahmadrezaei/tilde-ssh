import Foundation
import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH
import Testing
import TildeCore
@testable import TildeSSH

// MARK: - Server hello / KEXINIT

private func nameList(_ names: [String]) -> Data {
    let joined = Data(names.joined(separator: ",").utf8)
    return withUnsafeBytes(of: UInt32(joined.count).bigEndian) { Data($0) } + joined
}

/// A server KEXINIT as one binary packet (length, padding length, payload, padding).
private func kexInitPacket(kex: [String], hostKeys: [String], ciphers: [String], macs: [String]) -> Data {
    var payload = Data([20]) + Data(repeating: 7, count: 16)
    payload += nameList(kex) + nameList(hostKeys) + nameList(ciphers) + nameList(ciphers) + nameList(macs) + nameList(macs)
    payload += nameList(["none"]) + nameList(["none"]) + nameList([]) + nameList([])
    payload += Data([0]) + Data(repeating: 0, count: 4)
    let padding = 8 - ((payload.count + 5) % 8) + 4
    let length = UInt32(1 + payload.count + padding)
    return withUnsafeBytes(of: length.bigEndian) { Data($0) } + Data([UInt8(padding)]) + payload + Data(repeating: 0, count: padding)
}

@Suite struct ServerHelloTests {
    private let packet = kexInitPacket(
        kex: ["curve25519-sha256", "diffie-hellman-group14-sha256"], hostKeys: ["ssh-ed25519", "rsa-sha2-512"],
        ciphers: ["chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com"], macs: ["hmac-sha2-256"]
    )

    @Test func parsesTheNameLists() throws {
        let payload = packet.dropFirst(5).dropLast(Int(packet[4]))
        let kexInit = try #require(ServerKexInit.parse(payload: Data(payload)))
        #expect(kexInit.kexAlgorithms == ["curve25519-sha256", "diffie-hellman-group14-sha256"])
        #expect(kexInit.hostKeyAlgorithms == ["ssh-ed25519", "rsa-sha2-512"])
        #expect(kexInit.ciphersClientToServer == ["chacha20-poly1305@openssh.com", "aes256-gcm@openssh.com"])
        #expect(kexInit.macsClientToServer == ["hmac-sha2-256"])
        #expect(ServerKexInit.parse(payload: Data([21, 1, 2])) == nil)
        #expect(ServerKexInit.parse(payload: Data()) == nil)
    }

    @Test func snifferReadsBannerAndKexInitAcrossFragmentsAndForwardsEverything() throws {
        let box = ServerHelloBox()
        let channel = EmbeddedChannel(handler: ServerHelloSniffer(box: box))
        var stream = Data("Welcome to a test server\r\nSSH-2.0-OpenSSH_9.7\r\n".utf8) + packet
        var forwarded = 0
        // Feed in awkward 7-byte pieces.
        while !stream.isEmpty {
            let piece = stream.prefix(7)
            stream = Data(stream.dropFirst(7))
            try channel.writeInbound(ByteBuffer(bytes: piece))
        }
        while let out = try channel.readInbound(as: ByteBuffer.self) { forwarded += out.readableBytes }

        #expect(box.value.banner == "SSH-2.0-OpenSSH_9.7")
        #expect(box.value.kexInit?.kexAlgorithms.first == "curve25519-sha256")
        #expect(forwarded > packet.count, "bytes must pass through unchanged")
        _ = try? channel.finish()
    }

    @Test func snifferToleratesGarbage() throws {
        let box = ServerHelloBox()
        let channel = EmbeddedChannel(handler: ServerHelloSniffer(box: box))
        try channel.writeInbound(ByteBuffer(string: "<html>not ssh</html>\n"))
        #expect(box.value == ServerHello())
        _ = try? channel.finish()
    }

    @Test func negotiationPicksTheClientsFirstCommonChoice() {
        #expect(AlgorithmNegotiation.choose(client: ["a", "b", "c"], server: ["c", "b"]) == "b")
        #expect(AlgorithmNegotiation.choose(client: ["a"], server: ["z"]) == nil)
    }

    @Test func mismatchNamesTheFailingCategoryAndTheServersOffer() throws {
        let payload = packet.dropFirst(5).dropLast(Int(packet[4]))
        var server = try #require(ServerKexInit.parse(payload: Data(payload)))
        let ciphers = ["aes128-gcm@openssh.com"]
        #expect(AlgorithmNegotiation.firstMismatch(clientKex: ["curve25519-sha256"], clientCiphers: ["aes256-gcm@openssh.com"], server: server) == nil)

        server.kexAlgorithms = ["diffie-hellman-group1-sha1"]
        let kex = AlgorithmNegotiation.firstMismatch(clientKex: ["curve25519-sha256"], clientCiphers: ciphers, server: server)
        #expect(kex?.kind == "kex")
        #expect(kex?.offered == ["diffie-hellman-group1-sha1"])

        server.kexAlgorithms = ["curve25519-sha256"]
        server.hostKeyAlgorithms = ["ssh-dss"]
        #expect(AlgorithmNegotiation.firstMismatch(clientKex: ["curve25519-sha256"], clientCiphers: ciphers, server: server)?.kind == "host key")

        server.hostKeyAlgorithms = ["ssh-ed25519"]
        server.ciphersClientToServer = ["3des-cbc"]
        #expect(AlgorithmNegotiation.firstMismatch(clientKex: ["curve25519-sha256"], clientCiphers: ciphers, server: server)?.kind == "cipher")
    }
}

// MARK: - Reconnect policy and startup script

@Suite struct ReconnectPolicyTests {
    @Test func backoffScheduleMatchesTheDesign() {
        let policy = ReconnectPolicy.default
        #expect((1...8).map { policy.delay(forAttempt: $0) } == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30), .seconds(30), .seconds(30)])
        #expect(policy.delay(forAttempt: 0) == .seconds(1))
        #expect(policy.delay(forAttempt: 1000) == .seconds(30))
    }

    @Test func customScheduleAndDisabled() {
        #expect(ReconnectPolicy(schedule: []).delay(forAttempt: 3) == .seconds(1))
        #expect(ReconnectPolicy.disabled.isEnabled == false)
    }
}

@Suite struct StartupScriptTests {
    private func server(tmux: Bool = false, name: String = "tilde", command: String? = nil) -> ServerSnapshot {
        ServerSnapshot(name: "s", target: ConnectionTarget(host: "h", username: "u"), startupCommand: command, autoTmux: tmux, tmuxSessionName: name)
    }

    @Test func nothingByDefault() {
        #expect(StartupScript.lines(for: server()).isEmpty)
        #expect(StartupScript.lines(for: server(command: "   ")).isEmpty)
    }

    @Test func startupCommandOnly() {
        #expect(StartupScript.lines(for: server(command: " htop ")) == ["htop"])
    }

    @Test func tmuxAttachOrCreate() {
        #expect(StartupScript.lines(for: server(tmux: true)) == ["exec tmux new -A -s 'tilde'"])
        #expect(StartupScript.lines(for: server(tmux: true, name: "work.db:1")) == ["exec tmux new -A -s 'work-db-1'"])
        #expect(StartupScript.lines(for: server(tmux: true, name: "")) == ["exec tmux new -A -s 'tilde'"])
    }

    @Test func startupCommandRunsOnlyWhenTheTmuxSessionIsCreated() {
        let lines = StartupScript.lines(for: server(tmux: true, command: "tail -f /var/log/syslog"))
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("tmux has-session -t 'tilde' 2>/dev/null && exec tmux attach -t 'tilde' || exec tmux new -s 'tilde'"))
        #expect(lines[0].hasSuffix("send-keys 'tail -f /var/log/syslog' Enter"))
    }

    @Test func quotingSurvivesSingleQuotes() {
        #expect(StartupScript.shellQuote("it's") == "'it'\\''s'")
    }
}

// MARK: - Errors

@Suite struct ErrorMappingTests {
    private func map(_ error: any Error) -> SessionError { SessionErrorMapper.map(error, host: "h", timeoutSeconds: 15) }

    @Test func ownErrors() {
        #expect(map(DNSResolutionError(host: "x")) == .dnsFailure(host: "x"))
        #expect(map(ConnectTimeoutError(seconds: 9)) == .timeout(seconds: 9))
        #expect(map(AuthRejectedError(method: "publickey", serverAllows: ["password"])) == .authFailed(method: "publickey", serverAllows: ["password"]))
        #expect(map(HostKeyRejectedError()) == .hostKeyRejected)
        #expect(map(SessionError.refused) == .refused)
    }

    @Test func mismatchCarriesTheChallengeID() {
        let challenge = HostKeyChallenge(endpoint: HostEndpoint(host: "h"), serverName: nil,
                                         presented: HostKey(algorithm: "a", blobBase64: "b", fingerprintSHA256: "c"), lookup: .unknown)
        #expect(map(HostKeyMismatchError(challenge: challenge)) == .hostKeyMismatch(challengeID: challenge.id))
    }

    @Test func channelAndSocketErrors() {
        #expect(map(ChannelError.connectTimeout(.seconds(1))) == .timeout(seconds: 15))
        #expect(map(ChannelError.ioOnClosedChannel) == .networkLost)
        #expect(map(IOError(errnoCode: ECONNREFUSED, reason: "connect")) == .refused)
        #expect(map(IOError(errnoCode: ECONNRESET, reason: "read")) == .networkLost)
        #expect(map(IOError(errnoCode: ETIMEDOUT, reason: "connect")) == .timeout(seconds: 15))
        if case .underlying(let text) = map(IOError(errnoCode: EHOSTUNREACH, reason: "connect")) { #expect(text.contains("route")) } else { Issue.record("expected underlying") }
    }

    @Test func retriability() {
        #expect(SessionErrorMapper.isRetriable(.refused))
        #expect(SessionErrorMapper.isRetriable(.networkLost))
        #expect(SessionErrorMapper.isRetriable(.dnsFailure(host: "h")))
        #expect(SessionErrorMapper.isRetriable(.timeout(seconds: 1)))
        #expect(!SessionErrorMapper.isRetriable(.authFailed(method: "password", serverAllows: [])))
        #expect(!SessionErrorMapper.isRetriable(.hostKeyRejected))
        #expect(!SessionErrorMapper.isRetriable(.noCommonAlgorithm(kind: "kex", offered: [])))
    }
}

// MARK: - Host keys

@Suite @MainActor
struct HostKeyValidationTests {
    private let endpoint = HostEndpoint(host: "db.example.com", port: 22)
    private let presented = HostKey(algorithm: "ssh-ed25519", blobBase64: "AAAA", fingerprintSHA256: "SHA256:presented")

    private func configuration(
        store: InMemoryKnownHostsStore, prompter: AlwaysTrustPrompter?, strict: Bool = false, allowedOnce: Set<String> = [], timeout: Duration = .seconds(5)
    ) -> TOFUHostKeyValidator.Configuration {
        .init(endpoint: endpoint, serverName: "db", knownHosts: store, prompter: prompter.map(HostKeyAsker.init), strict: strict, promptTimeout: timeout, allowedOnce: allowedOnce)
    }

    @Test func fingerprintMatchesSSHKeygen() {
        // `ssh-keygen -lf` of the ed25519 test key in the fixtures.
        let blob = KeyFixtures.ed25519Public.split(separator: " ")[1]
        let fingerprint = HostKey.fingerprint(ofBlobBase64: String(blob))
        #expect(fingerprint.hasPrefix("SHA256:"))
        #expect(!fingerprint.hasSuffix("="))
        #expect(fingerprint.count == 7 + 43)
    }

    @Test func hostKeyFromNIOSSHKeyRoundTrips() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: KeyFixtures.ed25519Public)
        let hostKey = HostKey(key)
        #expect(hostKey.algorithm == "ssh-ed25519")
        #expect(hostKey.blobBase64 == String(KeyFixtures.ed25519Public.split(separator: " ")[1]))
        #expect(hostKey.fingerprintSHA256 == HostKey.fingerprint(ofBlobBase64: hostKey.blobBase64))
    }

    @Test func trustedKeyPassesWithoutPrompting() async throws {
        let store = InMemoryKnownHostsStore(pins: [endpoint: [presented]])
        let prompter = AlwaysTrustPrompter()
        try await TOFUHostKeyValidator.validate(presented, configuration: configuration(store: store, prompter: prompter), onPrompt: { _ in })
        #expect(prompter.challenges.isEmpty)
        #expect(await store.touched == [endpoint.canonical])
    }

    @Test func unknownKeyIsPromptedAndPinnedOnTrust() async throws {
        let store = InMemoryKnownHostsStore()
        let prompter = AlwaysTrustPrompter(decision: .trustAndSave)
        let waiting = Locked<[Bool]>([])
        try await TOFUHostKeyValidator.validate(presented, configuration: configuration(store: store, prompter: prompter), onPrompt: { flag in waiting.mutate { $0.append(flag) } })
        #expect(prompter.challenges.count == 1)
        #expect(prompter.challenges[0].lookup == .unknown)
        #expect(prompter.challenges[0].serverName == "db")
        #expect(await store.pinned(for: endpoint).count == 1)
        #expect(waiting.value == [true, false], "the connection timeout must pause while the sheet is up")
    }

    @Test func connectOnceDoesNotPinAndRejectThrows() async throws {
        let store = InMemoryKnownHostsStore()
        try await TOFUHostKeyValidator.validate(presented, configuration: configuration(store: store, prompter: AlwaysTrustPrompter(decision: .connectOnce)), onPrompt: { _ in })
        #expect(await store.pinned(for: endpoint).isEmpty)
        await #expect(throws: HostKeyRejectedError.self) {
            try await TOFUHostKeyValidator.validate(presented, configuration: configuration(store: store, prompter: AlwaysTrustPrompter(decision: .reject)), onPrompt: { _ in })
        }
    }

    @Test func strictModeAndMissingPrompterRejectUnknownKeys() async {
        let store = InMemoryKnownHostsStore()
        let prompter = AlwaysTrustPrompter()
        await #expect(throws: HostKeyRejectedError.self) {
            try await TOFUHostKeyValidator.validate(presented, configuration: configuration(store: store, prompter: prompter, strict: true), onPrompt: { _ in })
        }
        #expect(prompter.challenges.isEmpty)
        await #expect(throws: HostKeyRejectedError.self) {
            try await TOFUHostKeyValidator.validate(presented, configuration: configuration(store: store, prompter: nil), onPrompt: { _ in })
        }
    }

    @Test func differentPinnedKeyAbortsWithAChallengeAndNeverPrompts() async {
        let pinned = HostKey(algorithm: "ssh-ed25519", blobBase64: "BBBB", fingerprintSHA256: "SHA256:pinned")
        let store = InMemoryKnownHostsStore(pins: [endpoint: [pinned]])
        let prompter = AlwaysTrustPrompter()
        do {
            try await TOFUHostKeyValidator.validate(presented, configuration: configuration(store: store, prompter: prompter), onPrompt: { _ in })
            Issue.record("expected a mismatch")
        } catch let error as HostKeyMismatchError {
            #expect(error.challenge.presented == presented)
            guard case .mismatch(let pins) = error.challenge.lookup else { Issue.record("not a mismatch lookup"); return }
            #expect(pins.first?.key == pinned)
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(prompter.challenges.isEmpty, "the engine delivers mismatch challenges itself, after aborting")
    }

    @Test func allowedOnceFingerprintBypassesTheCheck() async throws {
        let pinned = HostKey(algorithm: "ssh-ed25519", blobBase64: "BBBB", fingerprintSHA256: "SHA256:pinned")
        let store = InMemoryKnownHostsStore(pins: [endpoint: [pinned]])
        try await TOFUHostKeyValidator.validate(presented, configuration: configuration(store: store, prompter: nil, allowedOnce: [presented.fingerprintSHA256]), onPrompt: { _ in })
    }

    @Test func unansweredPromptTimesOutAsRejection() async {
        let silent = SilentPrompter()
        let config = TOFUHostKeyValidator.Configuration(
            endpoint: endpoint, serverName: nil, knownHosts: InMemoryKnownHostsStore(), prompter: HostKeyAsker(silent),
            strict: false, promptTimeout: .milliseconds(100), allowedOnce: []
        )
        await #expect(throws: HostKeyRejectedError.self) {
            try await TOFUHostKeyValidator.validate(presented, configuration: config, onPrompt: { _ in })
        }
    }
}

/// A prompter that never answers.
@MainActor private final class SilentPrompter: HostKeyPrompter {
    func decide(_ challenge: HostKeyChallenge) async -> HostKeyDecision {
        await withCheckedContinuation { (_: CheckedContinuation<HostKeyDecision, Never>) in }
    }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
