import Foundation
import Observation
import SwiftData
import TildeCore
import TildeStore

/// The draft behind the Add / Edit Server form (design section 4.2). Plain `@Observable` state plus validation, saving
/// and "Test connection", so the logic is testable without a view.
@MainActor
@Observable
final class ServerEditorModel {
    enum Field: Hashable { case host, port, username, key, envVars, jump }

    enum TestState: Equatable {
        case idle
        case running
        case success(String)
        case failure(SessionErrorPresentation)
    }

    // Connection
    var name = ""
    var host = ""
    var portText = "22"
    var username = ""

    // Authentication
    var auth: AuthMethod = .key
    var key: SSHKeyRecord?
    /// A newly typed password. Empty keeps the saved one.
    var password = ""

    // Organize
    var environment: ServerEnvironment = .none
    var group: ServerGroup?
    var tags: [String] = []
    var isFavorite = false

    // Advanced
    var jump: Server?
    var startupCommand = ""
    var autoTmux = false
    var tmuxSessionName = "tilde"
    var keepAliveSeconds = 30
    var termType = "xterm-256color"
    var envVarsText = ""
    var notes = ""

    // State
    var testState: TestState = .idle
    private(set) var showsValidation = false
    let original: Server?
    let hasSavedPassword: Bool
    let isNew: Bool

    @ObservationIgnored private var testTask: Task<Void, Never>?

    // MARK: Init

    /// A blank server with defaults from Settings (default user, default key, TERM, keep-alive).
    init(keys: [SSHKeyRecord] = []) {
        original = nil
        isNew = true
        hasSavedPassword = false
        username = TildeSettings.currentDefaultUser
        termType = Self.storedString(TildeSettings.defaultTermKey) ?? TildeSettings.defaultTerm
        keepAliveSeconds = Self.storedInt(TildeSettings.defaultKeepAliveKey) ?? TildeSettings.defaultKeepAlive
        let defaultKey = UserDefaults.standard.string(forKey: TildeSettings.defaultKeyKey).flatMap(UUID.init(uuidString:))
        key = keys.first { $0.id == defaultKey } ?? keys.first
        auth = key == nil ? .passwordPrompt : .key
    }

    /// Edits an existing server.
    init(editing server: Server) {
        original = server
        isNew = false
        hasSavedPassword = server.passwordSecretID != nil
        name = server.name
        host = server.host
        portText = String(server.port)
        username = server.username
        auth = ServerMapper.authMethod(server)
        key = server.key
        environment = ServerMapper.environment(server)
        group = server.group
        tags = (server.tags ?? []).map(\.name).sorted()
        isFavorite = server.isFavorite
        jump = server.jumpServer
        startupCommand = server.startupCommand ?? ""
        autoTmux = server.autoTmux
        tmuxSessionName = server.tmuxSessionName
        keepAliveSeconds = server.keepAliveSeconds
        termType = server.termType
        envVarsText = Self.envVarsText(ServerMapper.envVars(json: server.envVarsJSON))
        notes = server.notes ?? ""
    }

    /// Prefilled from a Quick Connect session ("Save as server…").
    init(prefill request: SaveServerRequest, keys: [SSHKeyRecord]) {
        original = nil
        isNew = true
        hasSavedPassword = false
        let server = request.server
        name = server.name
        host = server.target.host
        portText = String(server.target.port)
        username = server.target.username
        auth = server.auth
        key = keys.first { $0.privateSecretID == server.keyID }
        if auth == .key, key == nil { auth = .passwordPrompt }
        environment = server.environment
        termType = server.termType
        keepAliveSeconds = server.keepAliveSeconds
        password = request.password ?? ""
        if auth == .passwordPrompt, !password.isEmpty { auth = .password }
    }

    // MARK: Derived

    var port: Int? { Int(portText.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } }
    var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Placeholder for Name: it fills from the host.
    var namePlaceholder: String { trimmedHost.isEmpty ? "prod-api-01" : trimmedHost }

    /// Ask every time (`passwordPrompt`) vs saved password.
    var asksEveryTime: Bool {
        get { auth == .passwordPrompt }
        set { auth = newValue ? .passwordPrompt : .password }
    }

    var isPasswordAuth: Bool { auth != .key }

    func issue(for field: Field) -> String? {
        switch field {
        case .host:
            if trimmedHost.isEmpty { return "Host is required" }
            if trimmedHost.contains(where: \.isWhitespace) { return "Host cannot contain spaces" }
            return nil
        case .port:
            return port == nil ? "Port must be 1-65535" : nil
        case .username:
            return nil   // empty falls back to the default user
        case .key:
            return auth == .key && key == nil ? "Choose a key, or switch to password" : nil
        case .envVars:
            return parsedEnvVars == nil ? "Use KEY=value, one per line" : nil
        case .jump:
            if let jump, let original, jump.id == original.id { return "A server cannot jump through itself" }
            if let jump, let original, jump.jumpServer?.id == original.id { return "That server already jumps through this one" }
            return nil
        }
    }

    var canSave: Bool {
        [Field.host, .port, .key, .envVars, .jump].allSatisfy { issue(for: $0) == nil }
    }

    func showValidation() { showsValidation = true }

    /// `nil` when a line is not `KEY=value`.
    var parsedEnvVars: [String: String]? {
        var result: [String: String] = [:]
        for line in envVarsText.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let eq = trimmed.firstIndex(of: "="), eq != trimmed.startIndex else { return nil }
            result[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
        }
        return result
    }

    static func envVarsText(_ vars: [String: String]) -> String {
        vars.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    // MARK: Paste helper

    /// Pasting `ssh -p 2222 -J bastion deploy@10.0.4.12` into Host splits it across the fields.
    func splitPastedCommand(using parser: any QuickConnectParsing, servers: [Server]) {
        guard host.contains(" ") || host.hasPrefix("ssh://") || host.contains("@"), let result = parser.parse(host) else { return }
        host = result.target.host
        portText = String(result.target.port)
        if !result.target.username.isEmpty { username = result.target.username }
        if let jumpTarget = result.jump {
            jump = servers.first { $0.host.caseInsensitiveCompare(jumpTarget.host) == .orderedSame && $0.port == jumpTarget.port } ?? jump
        }
    }

    // MARK: Test connection

    /// The snapshot used for "Test connection": the draft as it would be saved, without touching the store.
    /// A password typed but not saved yet is passed through a fixed prompter instead of the Keychain.
    func testSnapshot() -> (server: ServerSnapshot, typedPassword: String?)? {
        guard canSave, let port else { return nil }
        let usesTypedPassword = auth != .key && !password.isEmpty
        let effectiveAuth: AuthMethod = usesTypedPassword ? .passwordPrompt : auth
        let snapshot = ServerSnapshot(
            id: original?.id ?? UUID(),
            name: name.isEmpty ? trimmedHost : name,
            target: ConnectionTarget(host: trimmedHost, port: port, username: effectiveUsername),
            auth: effectiveAuth,
            keyID: auth == .key ? key?.privateSecretID : nil,
            passwordSecretID: auth == .password && !usesTypedPassword ? original?.passwordSecretID : nil,
            environment: environment,
            jump: jump.map(ServerMapper.jump),
            startupCommand: startupCommand.isEmpty ? nil : startupCommand,
            autoTmux: autoTmux,
            tmuxSessionName: tmuxSessionName,
            keepAliveSeconds: keepAliveSeconds,
            termType: termType,
            envVars: parsedEnvVars ?? [:]
        )
        return (snapshot, usesTypedPassword ? password : nil)
    }

    func test(services: TildeServices, coordinator: SessionCoordinator) {
        showsValidation = true
        guard let (snapshot, typed) = testSnapshot() else { return }
        testTask?.cancel()
        testState = .running
        let prompter = TestPasswordPrompter(typed: typed, fallback: coordinator)
        let keyName = key?.name
        testTask = Task { [weak self] in
            let request = SessionRequest(server: snapshot, connectTimeout: .seconds(TildeSettings.currentConnectTimeout))
            let result = await services.sessionEngine.test(
                request, credentials: services.credentials, knownHosts: services.knownHosts,
                hostKeyPrompter: coordinator, passwordPrompter: prompter
            )
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let info):
                self?.testState = .success(Self.successText(info, user: snapshot.target.username))
            case .failure(let error):
                self?.testState = .failure(SessionErrorCopy.present(error, server: snapshot, keyName: keyName))
            }
        }
    }

    func cancelTest() {
        testTask?.cancel()
        if testState == .running { testState = .idle }
    }

    /// `Authenticated as deploy (ed25519) in 182 ms`
    static func successText(_ info: ConnectionInfo, user: String) -> String {
        var text = "Authenticated as \(user) (\(authLabel(info.authenticatedWith)))"
        if let latency = info.latency { text += " in \(ReachabilityMonitor.milliseconds(latency)) ms" }
        return text
    }

    private static func authLabel(_ method: String) -> String {
        method.hasPrefix("ssh-") ? String(method.dropFirst(4)) : method
    }

    // MARK: Save

    var effectiveUsername: String {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? TildeSettings.currentDefaultUser : trimmed
    }

    /// Writes the draft to the store (and the password to the secret store). Returns `nil` if invalid.
    @discardableResult
    func save(context: ModelContext, secrets: any SecretStore) -> Server? {
        showsValidation = true
        guard canSave, let port else { return nil }
        let actions = ServerActions(context: context, secrets: secrets)
        let server = original ?? Server()
        let groupChanged = isNew || server.group?.id != group?.id

        server.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedHost : name.trimmingCharacters(in: .whitespaces)
        server.host = trimmedHost.lowercased()
        server.port = port
        server.username = effectiveUsername
        server.authMethodRaw = auth.rawValue
        server.key = auth == .key ? key : nil
        server.environmentRaw = environment.rawValue
        server.group = group
        server.tags = tags.map(actions.tag(named:))
        server.isFavorite = isFavorite
        server.jumpServer = jump
        server.startupCommand = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : startupCommand
        server.autoTmux = autoTmux
        server.tmuxSessionName = tmuxSessionName.isEmpty ? "tilde" : tmuxSessionName
        server.keepAliveSeconds = keepAliveSeconds
        server.termType = termType.isEmpty ? "xterm-256color" : termType
        server.envVarsJSON = ServerMapper.envVarsJSON(parsedEnvVars ?? [:])
        server.notes = notes.isEmpty ? nil : notes
        server.updatedAt = .now
        if groupChanged { server.sortIndex = actions.nextSortIndex(in: group) }

        applyPassword(to: server, secrets: secrets)

        if isNew { context.insert(server) }
        actions.save()
        return server
    }

    private func applyPassword(to server: Server, secrets: any SecretStore) {
        switch auth {
        case .password:
            guard !password.isEmpty else { return }   // keep the saved one
            let id = server.passwordSecretID ?? UUID()
            let label = "Tilde: \(server.username)@\(server.host)"
            do {
                try secrets.write(Data(password.utf8), for: SecretRef(kind: .password, id: id), label: label, synchronizable: true)
                server.passwordSecretID = id
            } catch {
                // The Keychain refused the write: never link an id with nothing behind it. The server asks for the
                // password at each connection instead of failing later with "secret not on this device".
                server.authMethodRaw = AuthMethod.passwordPrompt.rawValue
                server.passwordSecretID = nil
            }
        case .passwordPrompt, .key:
            // Ask every time stores nothing; key auth does not need a password.
            if let id = server.passwordSecretID { try? secrets.delete(SecretRef(kind: .password, id: id)) }
            server.passwordSecretID = nil
        }
    }

    // MARK: Helpers

    private static func storedString(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)
        return (value?.isEmpty ?? true) ? nil : value
    }

    private static func storedInt(_ key: String) -> Int? {
        UserDefaults.standard.object(forKey: key) as? Int
    }
}

/// Answers password prompts during "Test connection": with the password typed in the form, or (when none was typed)
/// by asking the user through the coordinator's sheet.
@MainActor
final class TestPasswordPrompter: PasswordPrompter {
    private let typed: String?
    private let fallback: SessionCoordinator

    init(typed: String?, fallback: SessionCoordinator) {
        self.typed = typed
        self.fallback = fallback
    }

    func password(for target: ConnectionTarget, reason: PromptReason) async -> String? {
        if let typed, reason != .rejected { return typed }
        return await fallback.password(for: target, reason: reason)
    }
}
