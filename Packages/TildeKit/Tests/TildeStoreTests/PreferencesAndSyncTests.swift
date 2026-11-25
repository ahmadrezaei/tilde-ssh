import Foundation
import Observation
import SwiftData
import Testing
import TildeCore
@testable import TildeStore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@MainActor
@Suite struct PreferencesTests {
    @Test func defaultsMatchTheDesign() {
        let prefs = Preferences.inMemory()
        #expect(prefs.appearance == .dark, "dark by default regardless of the system setting")
        #expect(prefs.terminalTheme == "Tilde Night")
        #expect(prefs.fontFamily == .sfMono && prefs.cursorStyle == .block && !prefs.cursorBlink && prefs.bellMode == .haptic)
        #expect(prefs.scrollbackLines == 10_000 && prefs.pasteConfirmation == .prodOnly)
        #expect(prefs.defaultUsername == "root" && prefs.defaultKeyID == nil && prefs.defaultKeepAliveSeconds == 30)
        #expect(prefs.connectTimeoutSeconds == 15 && prefs.autoReconnect && prefs.probeReachability && !prefs.probeOnCellular)
        #expect(prefs.appLockTimeout == .off && prefs.hideContentInAppSwitcher && !prefs.strictHostChecking)
        #expect(prefs.clipboardClearSeconds == 60 && prefs.optionAsMeta && prefs.commandPeriodSendsEscape && prefs.hapticsEnabled)
        #expect(prefs.keyBarLayoutData == nil && prefs.hardwareKeyboardModeRaw == "slimStrip")
        #expect(prefs.syncEnabled && !prefs.hasCompletedOnboarding)
        #expect(prefs.terminalFontSize >= 12)
    }

    @Test func valuesRoundTripThroughTheBackingStores() {
        let synced = InMemoryPreferenceBacking(), local = InMemoryPreferenceBacking()
        let prefs = Preferences(synced: synced, local: local)
        let keyID = UUID()
        prefs.appearance = .light
        prefs.terminalTheme = "Midnight High Contrast"
        prefs.defaultKeyID = keyID
        prefs.appLockTimeout = .fiveMinutes
        prefs.keyBarLayoutData = Data("{\"v\":1}".utf8)
        prefs.terminalFontSize = 15
        prefs.syncEnabled = false

        let again = Preferences(synced: synced, local: local)
        #expect(again.appearance == .light && again.terminalTheme == "Midnight High Contrast")
        #expect(again.defaultKeyID == keyID && again.appLockTimeout == .fiveMinutes)
        #expect(again.keyBarLayoutData == Data("{\"v\":1}".utf8))
        #expect(again.terminalFontSize == 15 && !again.syncEnabled)
        prefs.defaultKeyID = nil
        #expect(Preferences(synced: synced, local: local).defaultKeyID == nil)
    }

    @Test func syncedAndLocalValuesLandInTheRightStore() {
        let synced = InMemoryPreferenceBacking(), local = InMemoryPreferenceBacking()
        let prefs = Preferences(synced: synced, local: local)
        prefs.appearance = .system
        prefs.terminalFontSize = 14
        prefs.syncEnabled = false
        prefs.hardwareKeyboardModeRaw = "hidden"
        #expect(synced.object(forKey: Preferences.Key.appearance.rawValue) as? String == "system")
        #expect(synced.object(forKey: Preferences.Key.terminalFontSize.rawValue) == nil, "font size is per device")
        #expect(local.object(forKey: Preferences.Key.terminalFontSize.rawValue) as? Double == 14)
        #expect(local.object(forKey: Preferences.Key.syncEnabled.rawValue) as? Bool == false)
        #expect(local.object(forKey: Preferences.Key.hardwareKeyboardMode.rawValue) as? String == "hidden")
        for key in Preferences.Key.allCases {
            #expect(key.isSynced == key.rawValue.hasPrefix("pref."))
        }
    }

    @Test func numbersAreClamped() {
        let prefs = Preferences.inMemory()
        prefs.scrollbackLines = 5
        #expect(prefs.scrollbackLines == 1_000)
        prefs.scrollbackLines = 10_000_000
        #expect(prefs.scrollbackLines == 100_000)
        prefs.terminalFontSize = 2
        #expect(prefs.terminalFontSize == 9, "the terminal font never goes below 9 pt")
        prefs.connectTimeoutSeconds = 0
        #expect(prefs.connectTimeoutSeconds == 5)
        prefs.defaultKeepAliveSeconds = -4
        #expect(prefs.defaultKeepAliveSeconds == 0)
        prefs.clipboardClearSeconds = 99_999
        #expect(prefs.clipboardClearSeconds == 3_600)
    }

    @Test func garbageFromAnotherAppVersionFallsBackToDefaults() {
        let synced = InMemoryPreferenceBacking()
        synced.set("neon", forKey: Preferences.Key.appearance.rawValue)
        synced.set(7, forKey: Preferences.Key.terminalTheme.rawValue)
        synced.set("not-a-uuid", forKey: Preferences.Key.defaultKeyID.rawValue)
        synced.set(2_000_000, forKey: Preferences.Key.scrollbackLines.rawValue)
        synced.set("yes", forKey: Preferences.Key.autoReconnect.rawValue)
        let prefs = Preferences(synced: synced, local: InMemoryPreferenceBacking())
        #expect(prefs.appearance == .dark && prefs.terminalTheme == "Tilde Night" && prefs.defaultKeyID == nil)
        #expect(prefs.scrollbackLines == 100_000)
        #expect(prefs.autoReconnect == true)
    }

    @Test func blankTermTypeFallsBackToDefault() {
        let prefs = Preferences.inMemory()
        prefs.defaultTermType = "   "
        #expect(prefs.defaultTermType == "xterm-256color")
        prefs.defaultTermType = "screen-256color"
        #expect(prefs.defaultTermType == "screen-256color")
    }

    @Test func changesInvalidateObservers() {
        let synced = InMemoryPreferenceBacking()
        let prefs = Preferences(synced: synced, local: InMemoryPreferenceBacking())
        let invalidations = Counter()
        withObservationTracking { _ = prefs.appearance } onChange: { invalidations.increment() }
        prefs.appearance = .light
        #expect(invalidations.value == 1)

        // A change that arrived from another device (written straight to the store) shows up after reload().
        let externalInvalidations = Counter()
        withObservationTracking { _ = prefs.cursorStyle } onChange: { externalInvalidations.increment() }
        synced.set("bar", forKey: Preferences.Key.cursorStyle.rawValue)
        prefs.reload()
        #expect(externalInvalidations.value == 1 && prefs.cursorStyle == .bar)
    }

    @Test func unrecognisedAppLockValueKeepsTheLockOn() {
        let synced = InMemoryPreferenceBacking()
        let prefs = Preferences(synced: synced, local: InMemoryPreferenceBacking())
        #expect(prefs.appLockTimeout == .off, "never configured")
        synced.set("everyHour", forKey: Preferences.Key.appLockTimeout.rawValue)
        prefs.reload()
        #expect(prefs.appLockTimeout == .immediately, "a value from a newer version must not disable the lock")
        prefs.appLockTimeout = .fiveMinutes
        #expect(prefs.appLockTimeout == .fiveMinutes)
    }

    @Test func appLockTimeoutSeconds() {
        #expect(AppLockTimeout.off.seconds == nil)
        #expect(AppLockTimeout.immediately.seconds == 0)
        #expect(AppLockTimeout.fifteenMinutes.seconds == 900)
    }

    @Test func realBackingsConform() {
        // Compile-time check that the system stores can back Preferences.
        let suite = UserDefaults(suiteName: "tilde.tests.\(UUID().uuidString)")!
        let prefs = Preferences(synced: suite, local: suite)
        prefs.autoReconnect = false
        #expect(prefs.autoReconnect == false)
    }
}

@MainActor
@Suite struct SyncStatusTests {
    private func monitor(_ mode: StoreMode, syncEnabled: Bool = true, account: ICloudAccountStatus = .available) -> SyncStatusMonitor {
        SyncStatusMonitor(mode: mode, syncEnabled: syncEnabled, accountProvider: { account })
    }

    @Test func localStoreReportsDisabledWhateverTheAccount() async {
        for account in [ICloudAccountStatus.available, .noAccount, .restricted, .unknown] {
            let monitor = monitor(.local, syncEnabled: false, account: account)
            await monitor.refreshAccountStatus()
            #expect(monitor.status == .disabled)
            #expect(monitor.accountStatus == account)
        }
    }

    @Test func restartIsOnlyNeededWhenTheSyncSwitchChangesAfterLaunch() async {
        let monitor = monitor(.local, syncEnabled: false, account: .available)
        await monitor.refreshAccountStatus()
        #expect(!monitor.needsRestartToSync, "an available account alone never asks for a restart")
        monitor.syncPreference = true
        #expect(monitor.needsRestartToSync)
        monitor.syncPreference = false
        #expect(!monitor.needsRestartToSync)

        // CloudKit wanted but it could not start (local mode, preference still on): no endless banner.
        let failed = self.monitor(.local, syncEnabled: true, account: .available)
        await failed.refreshAccountStatus()
        #expect(!failed.needsRestartToSync && failed.status == .disabled)

        let syncing = self.monitor(.cloudKit(containerID: "iCloud.test"), syncEnabled: true)
        syncing.syncPreference = false
        #expect(syncing.needsRestartToSync, "switching sync off also takes effect after a restart")
    }

    @Test func signedOutUserWithTheCloudKitStoreSeesNoAccount() async {
        let monitor = monitor(.cloudKit(containerID: "iCloud.test"), account: .noAccount)
        await monitor.refreshAccountStatus()
        #expect(monitor.status == .noAccount && !monitor.needsRestartToSync)
    }

    @Test func cloudKitStoreFollowsEvents() async {
        let monitor = monitor(.cloudKit(containerID: "iCloud.test"))
        await monitor.refreshAccountStatus()
        #expect(monitor.status == .upToDate && monitor.lastSyncDate == nil)

        monitor.apply(SyncEvent(kind: .import, endDate: nil, succeeded: false))
        #expect(monitor.status == .syncing)

        let done = Date(timeIntervalSince1970: 1_800_000_000)
        monitor.apply(SyncEvent(kind: .import, endDate: done, succeeded: true))
        #expect(monitor.status == .upToDate && monitor.lastSyncDate == done)

        monitor.apply(SyncEvent(kind: .export, endDate: done.addingTimeInterval(5), succeeded: false, errorDescription: "Quota exceeded"))
        #expect(monitor.status == .error("Quota exceeded"))
        #expect(monitor.lastSyncDate == done, "a failure does not move the last-sync date")

        monitor.apply(SyncEvent(kind: .setup, endDate: done.addingTimeInterval(9), succeeded: true))
        #expect(monitor.status == .upToDate && monitor.lastSyncDate == done, "setup is not a data sync")
    }

    @Test func overlappingEventsStaySyncingUntilTheLastOneEnds() async {
        let monitor = monitor(.cloudKit(containerID: "iCloud.test"))
        monitor.apply(SyncEvent(kind: .import, endDate: nil, succeeded: false))
        monitor.apply(SyncEvent(kind: .export, endDate: nil, succeeded: false))
        monitor.apply(SyncEvent(kind: .import, endDate: .now, succeeded: true))
        #expect(monitor.status == .syncing)
        monitor.apply(SyncEvent(kind: .export, endDate: .now, succeeded: true))
        #expect(monitor.status == .upToDate)
    }

    @Test func accountProblemsOverrideEvents() async {
        let monitor = monitor(.cloudKit(containerID: "iCloud.test"), account: .restricted)
        await monitor.refreshAccountStatus()
        #expect(monitor.status == .restricted)
        let unavailable = self.monitor(.cloudKit(containerID: "iCloud.test"), account: .temporarilyUnavailable)
        await unavailable.refreshAccountStatus()
        #expect(unavailable.status == .temporarilyUnavailable)
    }

    @Test func inMemoryStoreNeverAsksForRestart() async {
        let monitor = monitor(.inMemory)
        monitor.syncPreference = false
        await monitor.refreshAccountStatus()
        #expect(!monitor.needsRestartToSync && monitor.status == .disabled)
    }
}

@Suite struct ContainerFactoryTests {
    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "tilde-tests-\(UUID().uuidString)/Tilde.store")
    }

    @Test func syncOffUsesTheLocalStoreWithAReason() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bootstrap = try ModelContainerFactory.makeBestAvailable(syncEnabled: false, storeURL: url, cloudKitCheck: { _ in true })
        #expect(bootstrap.mode == .local)
        #expect(bootstrap.cloudKitUnavailableReason != nil)
    }

    @Test func missingICloudFallsBackToLocalWithoutTryingCloudKit() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var asked: [String] = []
        let bootstrap = try ModelContainerFactory.makeBestAvailable(containerID: "iCloud.test", storeURL: url, cloudKitCheck: { asked.append($0); return false })
        #expect(asked == ["iCloud.test"])
        #expect(bootstrap.mode == .local && !bootstrap.mode.isSyncing)
    }

    @MainActor
    @Test func localStorePersistsAcrossContainers() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let container = try ModelContainerFactory.make(.local, storeURL: url)
            try ServerRepository(context: container.mainContext).add(Server(name: "persisted", host: "h", username: "u"))
        }
        let reopened = try ModelContainerFactory.make(.local, storeURL: url)
        #expect(try ServerRepository(context: reopened.mainContext).all().map(\.name) == ["persisted"])
    }

    @Test func infoPlistFlagMustBeExplicitlyTrue() {
        #expect(CloudKitAvailability.infoPlistEnabled(true))
        #expect(CloudKitAvailability.infoPlistEnabled("YES"))
        #expect(!CloudKitAvailability.infoPlistEnabled(nil), "a missing key means local mode")
        #expect(!CloudKitAvailability.infoPlistEnabled(false))
        #expect(!CloudKitAvailability.infoPlistEnabled("$(TILDE_CLOUDKIT_ENABLED)"), "an unexpanded build setting is not capable")
    }

    @Test func macNeedsBothTheEntitlementAndThePlistFlag() {
        let id = "iCloud.app.tildessh.Tilde"
        #expect(CloudKitAvailability.isCapableOnMac(entitledContainers: [id], containerID: id, plistValue: "YES"))
        #expect(!CloudKitAvailability.isCapableOnMac(entitledContainers: [id], containerID: id, plistValue: "NO"))
        #expect(!CloudKitAvailability.isCapableOnMac(entitledContainers: [id], containerID: id, plistValue: nil))
        #expect(!CloudKitAvailability.isCapableOnMac(entitledContainers: nil, containerID: id, plistValue: "YES"))
        #expect(!CloudKitAvailability.isCapableOnMac(entitledContainers: ["iCloud.other"], containerID: id, plistValue: true))
    }

    @Test func buildsWithoutTheICloudEntitlementAreNeverOfferedCloudKit() {
        // A container the test runner is not entitled to is never offered.
        #expect(!CloudKitAvailability.canUseCloudKit(containerID: "iCloud.nonexistent.\(UUID().uuidString)"))
    }

    @MainActor
    @Test func previewContainerIsSeeded() throws {
        let container = ModelContainerFactory.preview()
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Server>()) == PreviewServers.all.count)
        #expect(StoreMode.cloudKit(containerID: "x").isSyncing && !StoreMode.local.isSyncing && !StoreMode.inMemory.isSyncing)
    }
}
