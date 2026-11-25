import Foundation
import SwiftData
import Synchronization
import Testing
import TildeCore
import TildeSecurity
import TildeStore
@testable import TildeFeatures

/// A secret store whose writes fail (a locked or unavailable Keychain), recording what it was asked to do.
final class FailingWriteSecretStore: SecretStore {
    let status: OSStatus
    private let inner = InMemorySecretStore()
    let writeAttempts = Mutex(0)
    private let failingFlag = Mutex(true)

    var failing: Bool {
        get { failingFlag.withLock { $0 } }
        set { failingFlag.withLock { $0 = newValue } }
    }

    init(status: OSStatus = -25308) { self.status = status }

    func write(_ data: Data, for ref: SecretRef, label: String, synchronizable: Bool) throws {
        writeAttempts.withLock { $0 += 1 }
        if failing { throw KeychainError(status: status) }
        try inner.write(data, for: ref, label: label, synchronizable: synchronizable)
    }
    func read(_ ref: SecretRef) throws -> Data? { try inner.read(ref) }
    func delete(_ ref: SecretRef) throws { try inner.delete(ref) }
    func allRefs() throws -> [SecretRef] { try inner.allRefs() }
}

/// Answers prompts with a fixed string and records who was asked.
@MainActor
private final class RecordingPrompter: PasswordPrompter {
    private(set) var asked: [ConnectionTarget] = []
    let answer: String?
    init(answer: String?) { self.answer = answer }
    func password(for target: ConnectionTarget, reason: PromptReason) async -> String? {
        asked.append(target)
        return answer
    }
}

/// `ModelContext` does not retain its container, so tests park containers here for the life of the process.
private enum Containers {
    private static let kept = Mutex<[ModelContainer]>([])

    @MainActor
    static func context() throws -> ModelContext {
        let container = try ModelContainerFactory.make(.inMemory)
        kept.withLock { $0.append(container) }
        return container.mainContext
    }
}

@MainActor
@Suite struct ServerEditorKeychainFailureTests {
    private func passwordModel() -> ServerEditorModel {
        let model = ServerEditorModel(keys: [])
        model.host = "h.example.com"
        model.auth = .password
        model.password = "s3cret"
        return model
    }

    @Test func aFailedKeychainWriteIsReportedAndNothingIsSaved() throws {
        let context = try Containers.context()
        let secrets = FailingWriteSecretStore(status: -25308)
        let model = passwordModel()

        #expect(model.save(context: context, secrets: secrets) == nil)
        #expect(model.saveError == .keychain(-25308))
        #expect(model.saveError?.message == "Couldn't save the password in the Keychain (OSStatus -25308).")
        #expect(try context.fetch(FetchDescriptor<Server>()).isEmpty)
        // The draft is untouched: still password auth, with the typed password.
        #expect(model.auth == .password && model.password == "s3cret")
    }

    @Test func retryingAfterTheKeychainRecoversSaves() throws {
        let context = try Containers.context()
        let secrets = FailingWriteSecretStore()
        let model = passwordModel()
        #expect(model.save(context: context, secrets: secrets) == nil)

        secrets.failing = false
        let server = try #require(model.save(context: context, secrets: secrets))
        #expect(model.saveError == nil)
        #expect(server.authMethodRaw == "password")
        let id = try #require(server.passwordSecretID)
        #expect(try secrets.read(SecretRef(kind: .password, id: id)) == Data("s3cret".utf8))
        #expect(try context.fetch(FetchDescriptor<Server>()).count == 1)
    }

    @Test func askEveryTimeInsteadSavesWithoutTouchingTheKeychain() throws {
        let context = try Containers.context()
        let secrets = FailingWriteSecretStore()
        let model = passwordModel()
        #expect(model.save(context: context, secrets: secrets) == nil)

        model.useAskEveryTime()
        #expect(model.saveError == nil)
        let attempts = secrets.writeAttempts.withLock { $0 }
        let server = try #require(model.save(context: context, secrets: secrets))
        #expect(server.authMethodRaw == "passwordPrompt" && server.passwordSecretID == nil)
        #expect(secrets.writeAttempts.withLock { $0 } == attempts)
    }

    @Test func aFailedPasswordChangeLeavesTheExistingServerUntouched() throws {
        let context = try Containers.context()
        let secrets = FailingWriteSecretStore()
        secrets.failing = false
        let server = try #require(passwordModel().save(context: context, secrets: secrets))
        let id = try #require(server.passwordSecretID)

        secrets.failing = true
        let edit = ServerEditorModel(editing: server)
        edit.name = "renamed"
        edit.password = "new"
        #expect(edit.save(context: context, secrets: secrets) == nil)
        #expect(server.name != "renamed")
        #expect(server.passwordSecretID == id)
        #expect(server.authMethodRaw == "password")
        #expect(try secrets.read(SecretRef(kind: .password, id: id)) == Data("s3cret".utf8))
    }

    @Test func passwordAuthNeedsAPasswordUnlessOneIsSaved() throws {
        let model = ServerEditorModel(keys: [])
        model.host = "h"
        model.auth = .password
        #expect(!model.canSave)
        #expect(model.issue(for: .password) != nil)
        model.password = "x"
        #expect(model.canSave)
        model.asksEveryTime = true
        model.password = ""
        #expect(model.canSave)

        // An existing server with a saved password does not need it retyped.
        let context = try Containers.context()
        let saved = try #require(passwordModel().save(context: context, secrets: InMemorySecretStore()))
        let edit = ServerEditorModel(editing: saved)
        #expect(edit.auth == .password && edit.canSave)
    }
}

@MainActor
@Suite struct TestPasswordPrompterTests {
    private let target = ConnectionTarget(host: "App.Example.com", port: 22, username: "deploy")
    private let jump = ConnectionTarget(host: "bastion.example.com", port: 22, username: "ops")

    @Test func answersOnlyForTheServerUnderTest() async {
        let fallback = RecordingPrompter(answer: "from-sheet")
        let prompter = TestPasswordPrompter(typed: "typed", target: target, fallback: fallback)
        #expect(await prompter.password(for: ConnectionTarget(host: "app.example.com", port: 22, username: "deploy"), reason: .notSaved) == "typed")
        #expect(fallback.asked.isEmpty)
        // A jump host never gets the typed password: the user is asked instead.
        #expect(await prompter.password(for: jump, reason: .notSaved) == "from-sheet")
        #expect(fallback.asked == [jump])
        // Same host, different port or user: not the same server.
        #expect(await prompter.password(for: ConnectionTarget(host: "app.example.com", port: 2222, username: "deploy"), reason: .notSaved) == "from-sheet")
        #expect(await prompter.password(for: ConnectionTarget(host: "app.example.com", port: 22, username: "root"), reason: .notSaved) == "from-sheet")
    }

    @Test func aRejectedTypedPasswordIsNotSentAgain() async {
        let fallback = RecordingPrompter(answer: nil)
        let prompter = TestPasswordPrompter(typed: "typed", target: target, fallback: fallback)
        #expect(await prompter.password(for: target, reason: .rejected) == nil)
        #expect(fallback.asked == [target])
    }

    @Test func withNothingTypedEveryPromptGoesToTheUser() async {
        let fallback = RecordingPrompter(answer: "from-sheet")
        let prompter = TestPasswordPrompter(typed: nil, target: target, fallback: fallback)
        #expect(await prompter.password(for: target, reason: .notSaved) == "from-sheet")
    }
}

@MainActor
@Suite struct InstallKeyCredentialTests {
    private let target = ConnectionTarget(host: "app.example.com", username: "deploy")
    private let jump = ConnectionTarget(host: "bastion.example.com", username: "ops")
    private let ref = SecretRef(kind: .password, id: UUID())

    private struct Unavailable: CredentialResolver {
        let ref: SecretRef
        func resolve(auth: AuthMethod, keyID: UUID?, passwordSecretID: UUID?, target: ConnectionTarget) async throws -> ResolvedCredential {
            throw SessionError.secretUnavailable(ref)
        }
    }

    @Test func theTypedPasswordIsOnlyUsedForTheInstallTarget() async throws {
        let resolver = InstallCredentialResolver(base: Unavailable(ref: ref), passwordOverride: "typed", target: target)
        let forTarget = try await resolver.resolve(auth: .passwordPrompt, keyID: nil, passwordSecretID: nil, target: target)
        guard case .password(let typed) = forTarget else { Issue.record("expected a password credential"); return }
        #expect(typed == "typed")
        do {
            _ = try await resolver.resolve(auth: .password, keyID: nil, passwordSecretID: UUID(), target: jump)
            Issue.record("the jump host must not receive the typed password")
        } catch SessionError.secretUnavailable {
            // expected
        }
    }

    @Test func switchingToKeyDeletesTheOrphanedPasswordItem() throws {
        let secrets = InMemorySecretStore()
        let id = UUID()
        try secrets.write(Data("pw".utf8), for: SecretRef(kind: .password, id: id), label: "x", synchronizable: true)
        let server = Server(name: "s", host: "h", username: "u", authMethodRaw: "password")
        server.passwordSecretID = id
        let key = SSHKeyRecord(name: "k")

        InstallKeySheet.switchToKey(server, key: key, secrets: secrets)
        #expect(server.authMethodRaw == "key" && server.key === key && server.passwordSecretID == nil)
        #expect(try secrets.read(SecretRef(kind: .password, id: id)) == nil)
    }
}

@MainActor
@Suite struct UpdateSavedPasswordFailureTests {
    @Test func aFailedKeychainWriteShowsANoticeAndStillUsesTheTypedPassword() async throws {
        let secrets = FailingWriteSecretStore(status: -34018)
        var services = TildeServices.preview
        services.secretStore = secrets
        services.sessionEngine = FakeSessionEngine(connectDelay: .milliseconds(1))
        let coordinator = SessionCoordinator(services: services)
        let window = UUID()
        let server = PreviewServers.stagingWeb
        let tab = coordinator.open(server, in: window)
        let prompter = try #require(tab.prompter)

        let result = Task { await prompter.password(for: server.target, reason: .rejected) }
        await waitUntil { coordinator.pendingPassword(in: window) != nil }
        let request = try #require(coordinator.pendingPassword(in: window))
        coordinator.answerPassword(request, password: "new-secret", updateSaved: true)
        #expect(await result.value == "new-secret")
        #expect(tab.notice?.headline.contains("OSStatus -34018") == true)
    }
}
