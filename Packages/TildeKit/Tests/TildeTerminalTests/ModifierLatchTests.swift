import Testing
@testable import TildeTerminal

@Suite struct ModifierLatchTests {
    @Test func tapArmsOneShotThatConsumesOnce() {
        var latch = ModifierLatch()
        #expect(latch.isIdle)
        latch.tap(.ctrl, now: 0)
        #expect(latch.ctrl == .oneShot)
        #expect(latch.active == .ctrl)
        #expect(latch.consume() == .ctrl)
        #expect(latch.ctrl == .off)
        #expect(latch.consume().isEmpty)
    }

    @Test func doubleTapLocks() {
        var latch = ModifierLatch()
        latch.tap(.ctrl, now: 1.0)
        latch.tap(.ctrl, now: 1.2)
        #expect(latch.ctrl == .locked)
        #expect(latch.consume() == .ctrl)          // lock survives a key
        #expect(latch.ctrl == .locked)
        #expect(latch.consume() == .ctrl)
    }

    @Test func slowSecondTapDisarms() {
        var latch = ModifierLatch()
        latch.tap(.alt, now: 1.0)
        latch.tap(.alt, now: 1.5)
        #expect(latch.alt == .off)
    }

    @Test func tapWhileLockedUnlocks() {
        var latch = ModifierLatch()
        latch.tap(.ctrl, now: 0)
        latch.tap(.ctrl, now: 0.1)
        latch.tap(.ctrl, now: 5)
        #expect(latch.ctrl == .off)
    }

    @Test func modifiersCombine() {
        var latch = ModifierLatch()
        latch.tap(.ctrl, now: 0)
        latch.tap(.alt, now: 0.1)
        #expect(latch.active == [.ctrl, .alt])
        #expect(latch.consume() == [.ctrl, .alt])
        #expect(latch.isIdle)
    }

    @Test func lockedAndOneShotMix() {
        var latch = ModifierLatch()
        latch.tap(.ctrl, now: 0)
        latch.tap(.ctrl, now: 0.1)      // locked
        latch.tap(.alt, now: 0.5)       // one-shot
        #expect(latch.consume() == [.ctrl, .alt])
        #expect(latch.active == .ctrl)
    }

    @Test func resetClearsEverything() {
        var latch = ModifierLatch()
        latch.tap(.ctrl, now: 0)
        latch.tap(.ctrl, now: 0.1)
        latch.tap(.shift, now: 0.2)
        latch.reset()
        #expect(latch.isIdle)
        #expect(latch.phase(of: .ctrl) == .off)
    }

    @Test func tapAfterConsumeStartsOver() {
        var latch = ModifierLatch()
        latch.tap(.ctrl, now: 0)
        latch.consume()
        latch.tap(.ctrl, now: 0.1)      // within 300 ms of the first tap, but the state was off, so this is a fresh arm
        #expect(latch.ctrl == .oneShot)
    }
}
