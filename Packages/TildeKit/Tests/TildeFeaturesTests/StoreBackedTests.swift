import Foundation
import SwiftData
import Synchronization
import Testing
import TildeCore
import TildeStore
@testable import TildeFeatures

/// `ModelContext` does not retain its container, so tests park containers here for the life of the process.
private enum TestStore {
    private static let containers = Mutex<[ModelContainer]>([])

    @MainActor
    static func context() throws -> ModelContext {
        let container = try ModelContainerFactory.make(.inMemory)
        containers.withLock { $0.append(container) }
        return container.mainContext
    }
}

private final class CountingProbe: ReachabilityProbe {
    let count = Mutex(0)
    func probe(_ target: ConnectionTarget, timeout: Duration) async -> ProbeResult {
        count.withLock { $0 += 1 }
        return target.host == "down" ? .unreachable(reason: "refused") : .reachable(.milliseconds(42))
    }
}

@MainActor
@Suite struct ReachabilityMonitorTests {
    @Test func probesOnceThenThrottlesFor60Seconds() async {
        let probe = CountingProbe()
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let monitor = ReachabilityMonitor(prober: probe, now: { clock })
        let target = ConnectionTarget(host: "10.0.0.1", username: "u")

        #expect(monitor.status(for: target) == .unknown)
        monitor.refresh(target)
        monitor.refresh(target)   // already queued
        await waitUntil { monitor.status(for: target) == .reachable(milliseconds: 42) }
        #expect(probe.count.withLock { $0 } == 1)

        clock.addTimeInterval(30)
        monitor.refresh(target)   // inside the 60 s window
        try? await Task.sleep(for: .milliseconds(30))
        #expect(probe.count.withLock { $0 } == 1)

        clock.addTimeInterval(31)
        monitor.refresh(target)
        await waitUntil { probe.count.withLock { $0 } == 2 }
        #expect(probe.count.withLock { $0 } == 2)
    }

    @Test func forceBypassesTheThrottle() async {
        let probe = CountingProbe()
        let monitor = ReachabilityMonitor(prober: probe)
        let target = ConnectionTarget(host: "10.0.0.2", username: "u")
        monitor.refresh(target)
        await waitUntil { probe.count.withLock { $0 } == 1 }
        await waitUntil { monitor.status(for: target) != .probing }
        monitor.refresh(target, force: true)
        await waitUntil { probe.count.withLock { $0 } == 2 }
        #expect(probe.count.withLock { $0 } == 2)
    }

    @Test func unreachableAndStatusKeysIgnoreHostCase() async {
        let monitor = ReachabilityMonitor(prober: CountingProbe())
        let target = ConnectionTarget(host: "down", username: "u")
        monitor.refresh(target)
        await waitUntil { monitor.status(for: target) == .unreachable(reason: "refused") }
        #expect(monitor.status(for: ConnectionTarget(host: "DOWN", username: "other")) == .unreachable(reason: "refused"))
    }

    @Test func durationsConvertToMilliseconds() {
        #expect(ReachabilityMonitor.milliseconds(.milliseconds(182)) == 182)
        #expect(ReachabilityMonitor.milliseconds(.seconds(2)) == 2000)
        #expect(ReachabilityMonitor.milliseconds(.microseconds(1500)) == 1)
    }
}

@MainActor
@Suite struct ServerEditorModelTests {
    private func makeContext() throws -> ModelContext {
        try TestStore.context()
    }

    private func services(failure: SessionError? = nil) -> (TildeServices, InMemorySecretStore) {
        let secrets = InMemorySecretStore()
        var services = TildeServices.preview
        services.secretStore = secrets
        services.sessionEngine = FakeSessionEngine(failure: failure, connectDelay: .milliseconds(1))
        return (services, secrets)
    }

    @Test func validation() {
        let model = ServerEditorModel(keys: [])
        #expect(!model.canSave)
        #expect(model.issue(for: .host) == "Host is required")
        model.host = "db primary"
        #expect(model.issue(for: .host) == "Host cannot contain spaces")
        model.host = "db.example.com"
        #expect(model.issue(for: .host) == nil)
        model.portText = "70000"
        #expect(model.issue(for: .port) == "Port must be 1-65535")
        model.portText = "2222"
        #expect(model.port == 2222)
        #expect(model.canSave)   // no key records, so auth defaults to ask-every-time
        model.auth = .key
        #expect(model.issue(for: .key) != nil)
        #expect(!model.canSave)
    }

    @Test func newServersPreferTheFirstKeyWhenOneExists() throws {
        let key = SSHKeyRecord(name: "iphone-ed25519")
        let model = ServerEditorModel(keys: [key])
        #expect(model.auth == .key)
        #expect(model.key === key)
    }

    @Test func envVarsParseAndRoundTrip() {
        let model = ServerEditorModel(keys: [])
        model.envVarsText = "LANG=en_US.UTF-8\n\nEDITOR=vim"
        #expect(model.parsedEnvVars == ["LANG": "en_US.UTF-8", "EDITOR": "vim"])
        model.envVarsText = "not a pair"
        #expect(model.parsedEnvVars == nil)
        #expect(model.issue(for: .envVars) != nil)
        #expect(ServerEditorModel.envVarsText(["B": "2", "A": "1"]) == "A=1\nB=2")
    }

    @Test func savingANewPasswordServerWritesTheSecretAndNormalisesFields() throws {
        let context = try makeContext()
        let (services, secrets) = services()
        let model = ServerEditorModel(keys: [])
        model.host = "  Staging.Example.COM "
        model.portText = "2222"
        model.username = "deploy"
        model.auth = .password
        model.password = "s3cret"
        model.environment = .staging
        model.tags = ["web", "Edge"]
        model.autoTmux = true
        model.envVarsText = "LANG=C"

        let server = try #require(model.save(context: context, secrets: services.secretStore))
        #expect(server.host == "staging.example.com")
        #expect(server.name == "Staging.Example.COM")
        #expect(server.port == 2222)
        #expect(server.authMethodRaw == "password")
        #expect(server.environmentRaw == "staging")
        #expect(server.autoTmux)
        #expect(Set((server.tags ?? []).map(\.name)) == ["web", "Edge"])
        #expect(ServerMapper.envVars(json: server.envVarsJSON) == ["LANG": "C"])
        let id = try #require(server.passwordSecretID)
        #expect(try secrets.read(SecretRef(kind: .password, id: id)) == Data("s3cret".utf8))
        #expect(try context.fetch(FetchDescriptor<Server>()).count == 1)
    }

    @Test func askEveryTimeStoresNothingAndDeletesAnOldSecret() throws {
        let context = try makeContext()
        let (services, secrets) = services()
        let model = ServerEditorModel(keys: [])
        model.host = "h"
        model.auth = .password
        model.password = "pw"
        let server = try #require(model.save(context: context, secrets: services.secretStore))
        let id = try #require(server.passwordSecretID)

        let edit = ServerEditorModel(editing: server)
        #expect(edit.hasSavedPassword)
        edit.asksEveryTime = true
        _ = edit.save(context: context, secrets: services.secretStore)
        #expect(server.passwordSecretID == nil)
        #expect(try secrets.read(SecretRef(kind: .password, id: id)) == nil)
        #expect(server.authMethodRaw == "passwordPrompt")
    }

    @Test func editingWithoutTypingAPasswordKeepsTheSavedOne() throws {
        let context = try makeContext()
        let (services, secrets) = services()
        let model = ServerEditorModel(keys: [])
        model.host = "h"
        model.auth = .password
        model.password = "pw"
        let server = try #require(model.save(context: context, secrets: services.secretStore))
        let id = try #require(server.passwordSecretID)

        let edit = ServerEditorModel(editing: server)
        edit.name = "renamed"
        _ = edit.save(context: context, secrets: services.secretStore)
        #expect(server.passwordSecretID == id)
        #expect(try secrets.read(SecretRef(kind: .password, id: id)) == Data("pw".utf8))
        #expect(server.name == "renamed")
    }

    @Test func invalidDraftsDoNotSave() throws {
        let context = try makeContext()
        let model = ServerEditorModel(keys: [])
        #expect(model.save(context: context, secrets: InMemorySecretStore()) == nil)
        #expect(model.showsValidation)
        #expect(try context.fetch(FetchDescriptor<Server>()).isEmpty)
    }

    @Test func aServerCannotJumpThroughItselfOrACycle() throws {
        let context = try makeContext()
        let a = Server(name: "a", host: "a", username: "u")
        let b = Server(name: "b", host: "b", username: "u")
        context.insert(a); context.insert(b)
        b.jumpServer = a
        let model = ServerEditorModel(editing: a)
        model.jump = a
        #expect(model.issue(for: .jump) == "A server cannot jump through itself")
        model.jump = b
        #expect(model.issue(for: .jump) == "That server already jumps through this one")
        model.jump = nil
        #expect(model.issue(for: .jump) == nil)
    }

    @Test func pastingATargetSplitsItAcrossTheFields() {
        let model = ServerEditorModel(keys: [])
        model.host = "deploy@10.0.4.12:2222"
        model.splitPastedCommand(using: FakeQuickConnectParser(), servers: [])
        #expect(model.host == "10.0.4.12")
        #expect(model.portText == "2222")
        #expect(model.username == "deploy")
    }

    @Test func testConnectionReportsSuccess() async {
        let (services, _) = services()
        let coordinator = SessionCoordinator(services: services)
        let model = ServerEditorModel(keys: [])
        model.host = "10.0.1.12"
        model.username = "deploy"
        model.auth = .passwordPrompt
        model.test(services: services, coordinator: coordinator)
        #expect(model.testState == .running)
        await waitUntil { if case .running = model.testState { false } else { true } }
        #expect(model.testState == .success("Authenticated as deploy (ed25519) in 182 ms"))
    }

    @Test func testConnectionReportsFailureWithBannerCopy() async {
        let (services, _) = services(failure: .refused)
        let coordinator = SessionCoordinator(services: services)
        let model = ServerEditorModel(keys: [])
        model.host = "10.0.1.12"
        model.test(services: services, coordinator: coordinator)
        await waitUntil { if case .running = model.testState { false } else { true } }
        guard case .failure(let copy) = model.testState else {
            Issue.record("expected a failure, got \(model.testState)")
            return
        }
        #expect(copy.headline == "Connection refused · 10.0.1.12:22")
    }

    @Test func testConnectionNeedsAValidDraft() {
        let (services, _) = services()
        let model = ServerEditorModel(keys: [])
        model.test(services: services, coordinator: SessionCoordinator(services: services))
        #expect(model.testState == .idle)
        #expect(model.showsValidation)
    }

    @Test func typedPasswordGoesThroughAPrompterNotTheKeychain() throws {
        let model = ServerEditorModel(keys: [])
        model.host = "h"
        model.auth = .password
        model.password = "typed"
        let (snapshot, typed) = try #require(model.testSnapshot())
        #expect(snapshot.auth == .passwordPrompt)
        #expect(snapshot.passwordSecretID == nil)
        #expect(typed == "typed")
    }

    @Test func successTextFormats() {
        let info = ConnectionInfo(serverVersion: "", kex: "", cipher: "", authenticatedWith: "password", latency: nil)
        #expect(ServerEditorModel.successText(info, user: "root") == "Authenticated as root (password)")
    }
}

@MainActor
@Suite struct ServerActionsTests {
    private func setup() throws -> (ServerActions, ModelContext, InMemorySecretStore) {
        let context = try TestStore.context()
        let secrets = InMemorySecretStore()
        return (ServerActions(context: context, secrets: secrets), context, secrets)
    }

    private func add(_ context: ModelContext, _ name: String, sort: Double = 0, group: ServerGroup? = nil) -> Server {
        let server = Server(name: name, host: name, username: "u")
        server.sortIndex = sort
        server.group = group
        context.insert(server)
        return server
    }

    @Test func reorderRewritesOnlyTheMovedRow() throws {
        let (actions, context, _) = try setup()
        let rows = [add(context, "a", sort: 0), add(context, "b", sort: 1), add(context, "c", sort: 2)]
        actions.reorder(rows, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(rows.map(\.sortIndex) == [3, 1, 2])
    }

    @Test func duplicateCopiesFieldsAndClonesThePasswordSecret() throws {
        let (actions, context, secrets) = try setup()
        let original = add(context, "prod", sort: 4)
        original.environmentRaw = "prod"
        original.authMethodRaw = "password"
        let id = UUID()
        original.passwordSecretID = id
        try secrets.write(Data("pw".utf8), for: SecretRef(kind: .password, id: id), label: "x", synchronizable: true)

        let copy = actions.duplicate(original)
        #expect(copy.id != original.id)
        #expect(copy.name == "prod copy")
        #expect(copy.environmentRaw == "prod")
        #expect(copy.sortIndex == 5)
        let copyID = try #require(copy.passwordSecretID)
        #expect(copyID != id)
        #expect(try secrets.read(SecretRef(kind: .password, id: copyID)) == Data("pw".utf8))
    }

    @Test func deleteRemovesTheServerAndItsSecretUnlessShared() throws {
        let (actions, context, secrets) = try setup()
        let shared = UUID(), solo = UUID()
        let a = add(context, "a"), b = add(context, "b"), c = add(context, "c")
        a.passwordSecretID = shared
        b.passwordSecretID = shared
        c.passwordSecretID = solo
        for id in [shared, solo] { try secrets.write(Data("x".utf8), for: SecretRef(kind: .password, id: id), label: "x", synchronizable: true) }

        actions.delete(a)
        #expect(try secrets.read(SecretRef(kind: .password, id: shared)) != nil)
        actions.delete(c)
        #expect(try secrets.read(SecretRef(kind: .password, id: solo)) == nil)
        #expect(try context.fetch(FetchDescriptor<Server>()).count == 1)
    }

    @Test func movingToAGroupAppendsThere() throws {
        let (actions, context, _) = try setup()
        let group = actions.createGroup(named: " Prod ")
        #expect(group.name == "Prod")
        _ = add(context, "x", sort: 7, group: group)
        let mover = add(context, "y")
        actions.move(mover, to: group)
        #expect(mover.group?.id == group.id)
        #expect(mover.sortIndex == 8)
    }

    @Test func deletingAGroupKeepsItsServers() throws {
        let (actions, context, _) = try setup()
        let group = actions.createGroup(named: "G")
        let server = add(context, "s", group: group)
        actions.delete(group)
        #expect(server.group == nil)
        #expect(try context.fetch(FetchDescriptor<Server>()).count == 1)
    }

    @Test func tagsAreFoundCaseInsensitively() throws {
        let (actions, context, _) = try setup()
        let first = actions.tag(named: "K8s")
        let second = actions.tag(named: " k8S ")
        #expect(first === second)
        #expect(try context.fetch(FetchDescriptor<TildeStore.Tag>()).count == 1)
    }

    @Test func recentsKeepTheLastTenAndDeduplicate() throws {
        let (actions, context, _) = try setup()
        for index in 0..<12 {
            actions.recordRecent(ConnectionTarget(host: "h\(index)", username: "u"), server: nil)
        }
        actions.recordRecent(ConnectionTarget(host: "h11", username: "u"), server: nil)
        let recents = try context.fetch(FetchDescriptor<RecentConnection>())
        #expect(recents.count == 10)
        #expect(Set(recents.map(\.target)).count == 10)
        #expect(!recents.contains { $0.target == "u@h0" })
    }

    @Test func forgetHostKeyDeletesThePinnedKeys() throws {
        let (actions, context, _) = try setup()
        let server = add(context, "a")
        server.host = "10.0.1.12"
        server.port = 2222
        context.insert(KnownHost(endpoint: "[10.0.1.12]:2222", algorithm: "ssh-ed25519"))
        context.insert(KnownHost(endpoint: "other", algorithm: "ssh-ed25519"))
        actions.forgetHostKey(for: server)
        let remaining = try context.fetch(FetchDescriptor<KnownHost>())
        #expect(remaining.map(\.endpoint) == ["other"])
    }

    @Test func touchConnectedIsThrottled() throws {
        let (actions, context, _) = try setup()
        let server = add(context, "a")
        actions.touchConnected(serverID: server.id)
        let first = try #require(server.lastConnectedAt)
        server.lastConnectedAt = first.addingTimeInterval(-60)
        actions.touchConnected(serverID: server.id)
        #expect(server.lastConnectedAt == first.addingTimeInterval(-60))   // within 5 minutes: untouched
        server.lastConnectedAt = first.addingTimeInterval(-600)
        actions.touchConnected(serverID: server.id)
        #expect(server.lastConnectedAt! > first.addingTimeInterval(-600))
    }

    @Test func importHostsSkipsDuplicatesAndWiresProxyJump() throws {
        let (actions, context, _) = try setup()
        _ = add(context, "existing")
        let existing = try context.fetch(FetchDescriptor<Server>()).first!
        existing.host = "bastion.example.com"
        existing.port = 2222
        existing.username = "ops"

        let created = actions.importHosts([
            SSHConfigHost(alias: "bastion", hostName: "bastion.example.com", user: "ops", port: 2222),
            SSHConfigHost(alias: "prod-api", hostName: "10.0.1.12", user: "deploy", identityFiles: ["~/.ssh/id_ed25519"], proxyJump: "ops@bastion.example.com:2222"),
        ])
        #expect(created.map(\.name) == ["prod-api"])
        let api = try #require(created.first)
        #expect(api.jumpServer?.id == existing.id)
        #expect(api.importedFrom == "ssh_config:Host prod-api")
        #expect(api.authMethodRaw == "passwordPrompt")   // no key record named id_ed25519
    }
}
