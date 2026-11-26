import Foundation
import Testing
import TildeCore
import TildeDesign
import TildeStore
@testable import TildeFeatures

private func server(_ name: String, env: ServerEnvironment = .none, used: TimeInterval? = nil) -> HomeServer {
    HomeServer(
        id: UUID(), name: name, address: "deploy@\(name).example.com", environment: env,
        lastConnectedAt: used.map { Date(timeIntervalSince1970: $0) },
        probeTarget: ConnectionTarget(host: "\(name).example.com", username: "deploy")
    )
}

@Suite struct HomeRecentTests {
    @Test func newestFirstAndNeverUsedLeftOut() {
        let list = [server("a", used: 100), server("b"), server("c", used: 300), server("d", used: 200)]
        #expect(HomeLogic.recent(list).map(\.name) == ["c", "d", "a"])
    }

    @Test func limitAndTieOrder() {
        let list = [server("zed", used: 5), server("alpha", used: 5), server("old", used: 1)]
        #expect(HomeLogic.recent(list).map(\.name) == ["alpha", "zed", "old"])
        #expect(HomeLogic.recent(list, limit: 2).map(\.name) == ["alpha", "zed"])
    }
}

@Suite struct HomeSubmitTests {
    private let match = UUID()

    @Test func emptyTextDoesNothing() {
        #expect(HomeLogic.submit(text: "  ", parses: true, firstMatch: match) == .nothing)
    }

    @Test func addressConnects() {
        #expect(HomeLogic.submit(text: "deploy@10.0.0.4", parses: true, firstMatch: match) == .connect)
        #expect(HomeLogic.submit(text: "10.0.0.4", parses: true, firstMatch: nil) == .connect)
    }

    @Test func wordMatchingASavedServerOpensIt() {
        #expect(HomeLogic.submit(text: "prod", parses: true, firstMatch: match) == .open(match))
        #expect(HomeLogic.submit(text: "prod", parses: false, firstMatch: match) == .open(match))
    }

    @Test func unmatchedWordThatParsesConnects() {
        #expect(HomeLogic.submit(text: "bastion", parses: true, firstMatch: nil) == .connect)
        #expect(HomeLogic.submit(text: "???", parses: false, firstMatch: nil) == .nothing)
    }
}

@Suite struct EnvironmentSummaryTests {
    private typealias Entry = (environment: ServerEnvironment, status: ReachabilityMonitor.Status)

    @Test func oneCardPerEnvironmentProductionFirst() {
        let entries: [Entry] = [(.dev, .unknown), (.none, .unknown), (.prod, .unknown), (.dev, .unknown)]
        let summaries = EnvironmentSummary.summaries(entries)
        #expect(summaries.map(\.environment) == [.prod, .dev, .none])
        #expect(summaries.map(\.count) == [1, 2, 1])
    }

    @Test func nothingCheckedIsNotAllReachable() {
        let summary = EnvironmentSummary.summaries([(.prod, .unknown), (.prod, .probing)] as [Entry])[0]
        #expect(summary.label == "Not checked")
        #expect(summary.level == .unknown)
    }

    @Test func allReachable() {
        let summary = EnvironmentSummary.summaries([(.prod, .reachable(milliseconds: 20)), (.prod, .reachable(milliseconds: 149))] as [Entry])[0]
        #expect(summary.label == "All reachable")
        #expect(summary.level == .ok)
    }

    @Test func slowFromOneFiftyMilliseconds() {
        let summary = EnvironmentSummary.summaries([(.staging, .reachable(milliseconds: 150)), (.staging, .reachable(milliseconds: 20))] as [Entry])[0]
        #expect(summary.label == "1 slow")
        #expect(summary.level == .slow)
    }

    @Test func downAndSlowTogetherListDownFirst() {
        let entries: [Entry] = [(.prod, .unreachable(reason: "refused")), (.prod, .reachable(milliseconds: 400)), (.prod, .reachable(milliseconds: 5))]
        let summary = EnvironmentSummary.summaries(entries)[0]
        #expect(summary.label == "1 down, 1 slow")
        #expect(summary.level == .down)
    }

    @Test func partlyCheckedSaysSo() {
        let summary = EnvironmentSummary.summaries([(.lab, .reachable(milliseconds: 5)), (.lab, .unknown)] as [Entry])[0]
        #expect(summary.label == "1 of 2 reachable")
        #expect(summary.level == .unknown)
    }
}

@Suite struct ClosedSessionBannerTests {
    private let snapshot = ServerSnapshot(name: "prod-api-01", target: ConnectionTarget(host: "10.0.1.12", username: "deploy"))

    @Test func shellExit() {
        let closure = ClosedSession(server: snapshot, windowID: UUID(), reason: .exited(status: 0))
        #expect(HomeLogic.message(for: closure) == "prod-api-01: shell exited (0), tab closed")
        let unknown = ClosedSession(server: snapshot, windowID: UUID(), reason: .exited(status: nil))
        #expect(HomeLogic.message(for: unknown) == "prod-api-01: shell exited, tab closed")
    }

    @Test func userClosedAndError() {
        #expect(HomeLogic.message(for: ClosedSession(server: snapshot, windowID: UUID(), reason: .userClosed)) == "prod-api-01: tab closed")
        let failed = ClosedSession(server: snapshot, windowID: UUID(), reason: .error(.refused))
        #expect(HomeLogic.message(for: failed).hasPrefix("prod-api-01: Connection refused"))
    }
}

@MainActor
@Suite struct LastClosureTests {
    private func coordinator() -> SessionCoordinator {
        var services = TildeServices.preview
        services.sessionEngine = FakeSessionEngine(connectDelay: .milliseconds(1))
        return SessionCoordinator(services: services)
    }

    @Test func closingALiveTabRecordsUserClosedAndItsWindow() {
        let coordinator = coordinator()
        let window = UUID()
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        #expect(coordinator.lastClosure == nil)
        coordinator.close(tab)
        #expect(coordinator.lastClosure?.server == PreviewServers.prodAPI)
        #expect(coordinator.lastClosure?.windowID == window)
        #expect(coordinator.lastClosure?.reason == .userClosed)
        #expect(coordinator.recentlyClosed.first?.id == PreviewServers.prodAPI.id)
    }

    @Test func aShellThatExitedKeepsItsStatus() {
        let coordinator = coordinator()
        let window = UUID()
        let tab = coordinator.open(PreviewServers.prodAPI, in: window)
        coordinator.apply(.disconnected(.exited(status: 3)), to: tab)   // an exited shell closes its own tab
        #expect(coordinator.tab(id: tab.id) == nil)
        #expect(coordinator.lastClosure?.reason == .exited(status: 3))
        coordinator.close(tab)   // closing again is a no-op
        #expect(coordinator.recentlyClosed.count == 1)
    }
}

@Suite struct EnvVarRowTests {
    @Test func canonicalTextSurvivesARoundTrip() {
        let text = "LANG=en_US.UTF-8\nTZ=UTC"
        #expect(EnvVarRow.text(from: EnvVarRow.rows(from: text)) == text)
    }

    @Test func valueMayContainEquals() {
        let rows = EnvVarRow.rows(from: "OPTS=a=b")
        #expect(rows.first?.key == "OPTS")
        #expect(rows.first?.value == "a=b")
    }

    @Test func emptyRowsAreSkipped() {
        #expect(EnvVarRow.text(from: [EnvVarRow(), EnvVarRow(key: "A", value: "1"), EnvVarRow(key: "  ", value: "")]) == "A=1")
    }

    @Test func equalsAndLineBreaksNeverChangeTheMeaning() {
        let text = EnvVarRow.text(from: [EnvVarRow(key: "A=B", value: "c\nd")])
        #expect(text == "AB=cd")
    }

    @Test func duplicateKeys() {
        let rows = [EnvVarRow(key: "A", value: "1"), EnvVarRow(key: "B", value: "2"), EnvVarRow(key: "A ", value: "3")]
        #expect(EnvVarRow.duplicateKeys(in: rows) == ["A"])
    }
}

@MainActor
@Suite struct MacEditorPreviewTests {
    @Test func aValueWithoutAKeyKeepsTheModelFromSaving() {
        let model = ServerEditorModel()
        model.host = "10.0.0.1"
        model.auth = .passwordPrompt
        #expect(model.canSave)
        model.envVarsText = EnvVarRow.text(from: [EnvVarRow(key: "", value: "oops")])
        #expect(!model.canSave)
    }

    @Test func previewWorksWhileTheFormIsHalfFilled() {
        let model = ServerEditorModel()
        model.username = "deploy"
        #expect(model.sshPreview == "ssh deploy@hostname")
        model.host = "10.0.4.12"
        model.portText = "2222"
        #expect(model.sshPreview == "ssh -p 2222 deploy@10.0.4.12")
        model.portText = "nope"
        #expect(model.sshPreview == "ssh deploy@10.0.4.12")
    }

    @Test func targetOverloadMatchesTheSnapshotOne() {
        let snapshot = ServerSnapshot(
            name: "a", target: ConnectionTarget(host: "10.0.4.12", port: 2222, username: "deploy"),
            jump: JumpSnapshot(target: ConnectionTarget(host: "bastion", port: 2200, username: "ops"))
        )
        #expect(SSHCommand.string(target: snapshot.target, jump: snapshot.jump?.target) == SSHCommand.string(for: snapshot))
    }

    @Test func termChoicesAlwaysIncludeTheCurrentValue() {
        let model = ServerEditorModel()
        #expect(model.termChoices == ServerEditorModel.termTypes)
        model.termType = "rxvt-unicode"
        #expect(model.termChoices.first == "rxvt-unicode")
    }
}

@Suite struct MacEditorReturnTests {
    @Test func returnSavesAndConnectsExceptInProdAndFreeText() {
        #expect(MacEditorReturn.action(environment: .dev, isEditingFreeText: false) == .saveAndConnect)
        #expect(MacEditorReturn.action(environment: .none, isEditingFreeText: false) == .saveAndConnect)
        #expect(MacEditorReturn.action(environment: .prod, isEditingFreeText: false) == .save)
        #expect(MacEditorReturn.action(environment: .dev, isEditingFreeText: true) == .none)
        #expect(MacEditorReturn.action(environment: .prod, isEditingFreeText: true) == .none)
    }

    @Test func returnIsBoundToTheRightButtonAndNeverToSaveAndConnectInProd() {
        for environment in ServerEnvironment.allCases {
            for editing in [false, true] {
                let action = MacEditorReturn.action(environment: environment, isEditingFreeText: editing)
                let roles = [
                    MacEditorReturn.saveRole(environment: environment, isEditingFreeText: editing),
                    MacEditorReturn.saveAndConnectRole(environment: environment, isEditingFreeText: editing),
                ]
                #expect(roles.filter(\.bindsReturn).count == (action == .none ? 0 : 1))
                // Exactly one button is the filled one, however focus moves.
                #expect(roles.filter { $0.look == .primary }.count == 1)
                if environment == .prod { #expect(!roles[1].bindsReturn) }
            }
        }
    }
}

#if os(macOS)
@Suite struct TokenListTests {
    @Test func trimsDropsEmptiesAndRepeatsKeepingOrder() {
        let tokens: [Any] = ["web", " db, ", "WEB", "", "edge", 4, "Db"]
        #expect(TildeTokenField.normalized(tokens) == ["web", "db", "edge"])
    }
}
#endif

@Suite struct HomeServerMappingTests {
    @Test func addressOmitsPort22AndTheProbeTargetIsTheServerItself() {
        let model = Server(name: "", host: "a.example.com", port: 22, username: "deploy", environmentRaw: "prod")
        let item = HomeServer(model)
        #expect(item.address == "deploy@a.example.com")
        #expect(item.name == "a.example.com")
        #expect(item.environment == .prod)
        #expect(item.probeTarget == ConnectionTarget(host: "a.example.com", port: 22, username: "deploy"))
        model.port = 2222
        #expect(HomeServer(model).address == "deploy@a.example.com:2222")
    }

    @Test func bareAddressThatMatchesASavedServerOpensIt() {
        let id = UUID()
        #expect(HomeLogic.submit(text: "10.0.0.4", parses: true, firstMatch: id) == .open(id))
    }
}
