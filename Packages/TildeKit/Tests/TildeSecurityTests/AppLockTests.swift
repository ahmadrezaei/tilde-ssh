import Foundation
import Testing
import TildeCore
@testable import TildeSecurity

/// App lock state machine, driven by a stub authenticator and a manual clock.
@MainActor
@Suite struct AppLockTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000_000)
        func now() -> Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    }

    private func makeSettings(enabled: Bool = true, timeout: AppLockTimeout = .immediately) -> SecuritySettings {
        let defaults = UserDefaults(suiteName: "tilde.tests.\(UUID().uuidString)")!
        let settings = SecuritySettings(defaults: defaults)
        settings.appLockEnabled = enabled
        settings.lockTimeout = timeout
        return settings
    }

    private func makeLock(_ settings: SecuritySettings, authenticator: StubAuthenticator = StubAuthenticator(), clock: Clock = Clock()) -> AppLock {
        AppLock(settings: settings, authenticator: authenticator, now: { clock.now() })
    }

    @Test func startsLockedOnlyWhenEnabled() {
        #expect(makeLock(makeSettings(enabled: true)).isLocked)
        #expect(!makeLock(makeSettings(enabled: false)).isLocked)
        // A device that cannot authenticate cannot be locked (it would never open again).
        #expect(!makeLock(makeSettings(enabled: true), authenticator: StubAuthenticator(canAuthenticate: false)).isLocked)
    }

    @Test func unlockSucceedsAndFails() async {
        let good = makeLock(makeSettings())
        #expect(await good.unlock())
        #expect(!good.isLocked)

        let bad = makeLock(makeSettings(), authenticator: StubAuthenticator(succeeds: false))
        #expect(await bad.unlock() == false)
        #expect(bad.isLocked)
        #expect(bad.lastAttemptFailed)
    }

    @Test func lockNowRelocks() async {
        let lock = makeLock(makeSettings(enabled: false))
        lock.lockNow()
        #expect(lock.isLocked)
        #expect(await lock.unlock())
        #expect(!lock.isLocked)
        let noAuth = makeLock(makeSettings(enabled: false), authenticator: StubAuthenticator(canAuthenticate: false))
        noAuth.lockNow()
        #expect(!noAuth.isLocked)
    }

    @Test func relocksAfterTimeout() async {
        let clock = Clock()
        let lock = makeLock(makeSettings(timeout: .oneMinute), clock: clock)
        _ = await lock.unlock()
        lock.sceneDidChange(.background)
        clock.advance(30)
        lock.sceneDidChange(.active)
        #expect(!lock.isLocked)  // within the grace period

        lock.sceneDidChange(.background)
        clock.advance(61)
        lock.sceneDidChange(.active)
        #expect(lock.isLocked)
    }

    @Test func immediateTimeoutLocksOnEveryReturnFromBackground() async {
        let lock = makeLock(makeSettings(timeout: .immediately))
        _ = await lock.unlock()
        lock.sceneDidChange(.background)
        lock.sceneDidChange(.active)
        #expect(lock.isLocked)
    }

    @Test func disabledLockNeverLocks() {
        let clock = Clock()
        let lock = makeLock(makeSettings(enabled: false), clock: clock)
        lock.sceneDidChange(.background)
        clock.advance(10_000)
        lock.sceneDidChange(.active)
        #expect(!lock.isLocked)
    }

    @Test func settingsToggleRequiresAuthentication() async {
        let settings = makeSettings(enabled: false)
        let failing = makeLock(settings, authenticator: StubAuthenticator(succeeds: false))
        #expect(await failing.setEnabled(true) == false)
        #expect(!settings.appLockEnabled)

        let lock = makeLock(settings)
        #expect(await lock.setEnabled(true))
        #expect(settings.appLockEnabled)

        // Turning it off also needs a successful prompt.
        let refusing = makeLock(settings, authenticator: StubAuthenticator(succeeds: false))
        #expect(await refusing.setEnabled(false) == true)
        #expect(settings.appLockEnabled)
        #expect(await lock.setEnabled(false) == false)
        #expect(!settings.appLockEnabled)
        #expect(!lock.isLocked)
    }

    @Test func privacyCoverFollowsPhaseOnIOSAndLockEverywhere() async {
        let lock = makeLock(makeSettings(enabled: false))
        #expect(!lock.isPrivacyCoverVisible)
        lock.sceneDidChange(.inactive)
        #if os(iOS)
        #expect(lock.isPrivacyCoverVisible)
        lock.settings.hideContentInSwitcher = false
        #expect(!lock.isPrivacyCoverVisible)
        #else
        #expect(!lock.isPrivacyCoverVisible)
        #endif
        lock.sceneDidChange(.active)
        lock.lockNow()
        #expect(lock.isPrivacyCoverVisible)
    }

    // MARK: Several scenes (iPad windows)

    @Test func aBackgroundedSceneDoesNotCoverOrRelockTheActiveOne() async {
        let clock = Clock()
        let lock = makeLock(makeSettings(timeout: .immediately), clock: clock)
        _ = await lock.unlock()
        let front = UUID(), back = UUID()
        lock.sceneDidChange(.active, scene: front)
        lock.sceneDidChange(.active, scene: back)

        lock.sceneDidChange(.background, scene: back)
        #expect(lock.phase == .active)
        #expect(!lock.isPrivacyCoverVisible)
        clock.advance(600)
        lock.sceneDidChange(.active, scene: back)
        #expect(!lock.isLocked)

        lock.sceneDidChange(.background, scene: back)
        lock.sceneDidChange(.inactive, scene: front)
        #expect(lock.phase == .inactive)
        #if os(iOS)
        #expect(lock.isPrivacyCoverVisible)
        #endif
    }

    @Test func theLockTimeoutRunsFromTheMomentEverySceneIsInTheBackground() async {
        let clock = Clock()
        let lock = makeLock(makeSettings(timeout: .oneMinute), clock: clock)
        _ = await lock.unlock()
        let a = UUID(), b = UUID()
        lock.sceneDidChange(.active, scene: a)
        lock.sceneDidChange(.active, scene: b)

        lock.sceneDidChange(.background, scene: a)
        clock.advance(120)                       // only one window is away: the app is still in use
        lock.sceneDidChange(.background, scene: b)
        #expect(lock.phase == .background)
        clock.advance(30)
        lock.sceneDidChange(.active, scene: a)   // back inside the minute
        #expect(!lock.isLocked)

        lock.sceneDidChange(.background, scene: a)
        clock.advance(61)
        lock.sceneDidChange(.active, scene: b)   // any window coming back is the app coming back
        #expect(lock.isLocked)
    }

    @Test func aClosedSceneStopsCounting() async {
        let lock = makeLock(makeSettings(enabled: false))
        let a = UUID(), b = UUID()
        lock.sceneDidChange(.active, scene: a)
        lock.sceneDidChange(.background, scene: b)
        #expect(lock.phase == .active)
        lock.sceneDidDisappear(a)
        #expect(lock.phase == .background)
        lock.sceneDidDisappear(b)
        #expect(lock.phase == .background)   // nothing left to report: unchanged
    }

    @Test func settingsPersistAndHaveSensibleDefaults() {
        let suite = "tilde.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let fresh = SecuritySettings(defaults: defaults)
        #expect(!fresh.appLockEnabled)
        #expect(fresh.lockTimeout == .immediately)
        #expect(fresh.hideContentInSwitcher)
        #expect(!fresh.strictHostChecking)
        #expect(fresh.clipboardClearSeconds == 60)

        fresh.appLockEnabled = true
        fresh.lockTimeout = .fiveMinutes
        fresh.hideContentInSwitcher = false
        fresh.strictHostChecking = true
        fresh.clipboardClearSeconds = 0
        let reloaded = SecuritySettings(defaults: UserDefaults(suiteName: suite)!)
        #expect(reloaded.appLockEnabled)
        #expect(reloaded.lockTimeout == .fiveMinutes)
        #expect(!reloaded.hideContentInSwitcher)
        #expect(reloaded.strictHostChecking)
        #expect(reloaded.clipboardClearSeconds == 0)
    }
}
