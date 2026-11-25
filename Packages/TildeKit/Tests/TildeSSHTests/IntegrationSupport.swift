import Foundation
import Synchronization
import TildeCore
@testable import TildeSSH

/// Helpers for the Docker-backed tests. They only run with `TILDE_SSH_INTEGRATION=1` and the containers from
/// `ci/sshd` up (`./generate-keys.sh && docker compose up -d --build`).
enum Lab {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var isEnabled: Bool { environment["TILDE_SSH_INTEGRATION"] == "1" }

    /// The CI script exports `TILDE_TEST_SSH_*` for one key-only sshd. When those are set the Docker lab
    /// (password users, bastion, legacy servers) is not available, and `CIServerTests` run instead.
    static var usesCIServer: Bool { environment["TILDE_TEST_SSH_PORT"] != nil }

    /// Docker lab suites run with `TILDE_SSH_INTEGRATION=1` and no CI server configured.
    static var isDockerLabEnabled: Bool { isEnabled && !usesCIServer }
    static var isCIServerEnabled: Bool { isEnabled && usesCIServer }

    static var host: String { environment["TILDE_TEST_SSH_HOST"] ?? "127.0.0.1" }
    static let targetPort = 2201
    static let bastionPort = 2202
    static let legacyPort = 2203
    static let noKexPort = 2204
    static let dropbearPort = 2205
    static let password = "tilde-test-pw"

    /// `ci/sshd/keys`, or `TILDE_SSH_KEYS_DIR`.
    static var keysDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TILDE_SSH_KEYS_DIR"] { return URL(fileURLWithPath: override) }
        // .../Packages/TildeKit/Tests/TildeSSHTests/IntegrationSupport.swift -> repository root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appending(path: "ci/sshd/keys")
    }

    static func keyMaterial(_ name: String) throws -> PrivateKeyMaterial {
        let data = try Data(contentsOf: keysDirectory.appending(path: name))
        return PrivateKeyMaterial(algorithm: .ed25519, openSSHBytes: data)
    }

    static func server(
        user: String, port: Int = targetPort, host: String = Lab.host, auth: AuthMethod = .password,
        keepAlive: Int = 0, jump: JumpSnapshot? = nil, autoTmux: Bool = false, startupCommand: String? = nil
    ) -> ServerSnapshot {
        ServerSnapshot(
            name: "lab", target: ConnectionTarget(host: host, port: port, username: user), auth: auth,
            keyID: auth == .key ? UUID() : nil, passwordSecretID: auth == .password ? UUID() : nil,
            jump: jump, startupCommand: startupCommand, autoTmux: autoTmux, keepAliveSeconds: keepAlive
        )
    }

    /// Runs `docker compose` in `ci/sshd`.
    @discardableResult
    static func compose(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "compose"] + arguments
        process.currentDirectoryURL = keysDirectory.deletingLastPathComponent()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Resolves a fixed password or a key file from `ci/sshd/keys`.
struct LabCredentials: CredentialResolver {
    var password: String = Lab.password
    var keyFile: String?
    var jumpPassword: String = Lab.password

    func resolve(auth: AuthMethod, keyID: UUID?, passwordSecretID: UUID?, target: ConnectionTarget) async throws -> ResolvedCredential {
        switch auth {
        case .password, .passwordPrompt:
            return .password(target.port == Lab.bastionPort ? jumpPassword : password)
        case .key:
            guard let keyFile else { throw SessionError.secretUnavailable(SecretRef(kind: .privateKey, id: keyID ?? UUID())) }
            return .privateKey(try Lab.keyMaterial(keyFile))
        }
    }
}

/// Answers password prompts from a script and records why it was asked.
@MainActor final class ScriptedPasswordPrompter: PasswordPrompter {
    var answers: [String?]
    private(set) var reasons: [PromptReason] = []

    init(_ answers: [String?]) { self.answers = answers }

    func password(for target: ConnectionTarget, reason: PromptReason) async -> String? {
        reasons.append(reason)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

/// Collects a session's output and states so tests can wait for them.
final class SessionRecorder: Sendable {
    private let text = Mutex("")
    private let states = Mutex<[SessionState]>([])

    init(_ session: any TerminalSession) {
        Task { [self] in for await data in session.output { text.withLock { $0 += String(decoding: data, as: UTF8.self) } } }
        Task { [self] in for await state in session.states { states.withLock { $0.append(state) } } }
    }

    var output: String { text.withLock { $0 } }
    var allStates: [SessionState] { states.withLock { $0 } }
    var lastState: SessionState? { allStates.last }

    /// Waits until the session is no longer idle or mid-connect (the recorder lags the session by a hop).
    func settle(timeout: Duration = .seconds(5)) async {
        _ = await wait(timeout: timeout) {
            switch lastState {
            case .none, .idle?, .connecting?: false
            default: true
            }
        }
    }

    func waitForOutput(_ needle: String, timeout: Duration = .seconds(10)) async -> Bool {
        await wait(timeout: timeout) { output.contains(needle) }
    }

    func waitForState(timeout: Duration = .seconds(15), _ predicate: @escaping @Sendable (SessionState) -> Bool) async -> Bool {
        await wait(timeout: timeout) { allStates.contains(where: predicate) }
    }

    private func wait(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}


/// The single key-only sshd started by the CI script.
enum CIServer {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var host: String { environment["TILDE_TEST_SSH_HOST"] ?? "127.0.0.1" }
    static var port: Int { Int(environment["TILDE_TEST_SSH_PORT"] ?? "") ?? 2222 }
    static var user: String { environment["TILDE_TEST_SSH_USER"] ?? NSUserName() }

    static func keyMaterial(_ variable: String) throws -> PrivateKeyMaterial {
        guard let path = environment[variable] else { throw SessionError.underlying("\(variable) is not set") }
        return PrivateKeyMaterial(algorithm: .ed25519, openSSHBytes: try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// The server's host key from `TILDE_TEST_SSH_HOST_KEY` (a `.pub` file).
    static func hostKey() throws -> HostKey {
        guard let path = environment["TILDE_TEST_SSH_HOST_KEY"] else { throw SessionError.underlying("TILDE_TEST_SSH_HOST_KEY is not set") }
        let line = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ")
        return HostKey(algorithm: String(parts[0]), blobBase64: String(parts[1]), fingerprintSHA256: HostKey.fingerprint(ofBlobBase64: String(parts[1])))
    }

    static func server() -> ServerSnapshot {
        ServerSnapshot(
            name: "ci", target: ConnectionTarget(host: host, port: port, username: user), auth: .key,
            keyID: UUID(), keepAliveSeconds: 0
        )
    }
}

/// Resolves the key file named by one of the `TILDE_TEST_SSH_KEY_*` variables.
struct CICredentials: CredentialResolver {
    var variable: String
    func resolve(auth: AuthMethod, keyID: UUID?, passwordSecretID: UUID?, target: ConnectionTarget) async throws -> ResolvedCredential {
        .privateKey(try CIServer.keyMaterial(variable))
    }
}
