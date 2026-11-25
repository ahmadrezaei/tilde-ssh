import Foundation

/// The state of one sticky modifier key on the key bar.
public enum LatchPhase: Equatable, Sendable {
    /// Not applied to anything.
    case off
    /// Applies to the next key from any source, then turns off.
    case oneShot
    /// Applies to every key until tapped again.
    case locked
}

/// Sticky modifier logic (docs/DESIGN.md section 5.3): tap = one-shot, double-tap (under 300 ms) = lock,
/// tap while armed after that = off. Pure value type with an explicit clock so it is unit-testable.
public struct ModifierLatch: Equatable, Sendable {
    /// Maximum gap between two taps that counts as a double-tap.
    public static let doubleTapInterval: TimeInterval = 0.3

    public private(set) var ctrl: LatchPhase = .off
    public private(set) var alt: LatchPhase = .off
    public private(set) var shift: LatchPhase = .off

    private var ctrlTapTime: TimeInterval = -.infinity
    private var altTapTime: TimeInterval = -.infinity
    private var shiftTapTime: TimeInterval = -.infinity

    public init() {}

    /// Phase of one modifier.
    public func phase(of modifier: KeyModifiers) -> LatchPhase {
        switch modifier {
        case .ctrl: ctrl
        case .alt: alt
        case .shift: shift
        default: .off
        }
    }

    /// Modifiers that apply to the next key (one-shot and locked).
    public var active: KeyModifiers {
        var m: KeyModifiers = []
        if ctrl != .off { m.insert(.ctrl) }
        if alt != .off { m.insert(.alt) }
        if shift != .off { m.insert(.shift) }
        return m
    }

    public var isIdle: Bool { active.isEmpty }

    /// A tap on a modifier key. `now` is a monotonic time in seconds.
    public mutating func tap(_ modifier: KeyModifiers, now: TimeInterval) {
        switch modifier {
        case .ctrl: Self.advance(&ctrl, &ctrlTapTime, now)
        case .alt: Self.advance(&alt, &altTapTime, now)
        case .shift: Self.advance(&shift, &shiftTapTime, now)
        default: break
        }
    }

    /// Returns the modifiers to apply to a key that is being sent and turns off the one-shot ones.
    @discardableResult
    public mutating func consume() -> KeyModifiers {
        let applied = active
        if ctrl == .oneShot { ctrl = .off }
        if alt == .oneShot { alt = .off }
        if shift == .oneShot { shift = .off }
        return applied
    }

    /// Locks a modifier directly (the VoiceOver "Lock" action, where double-tap timing is not available).
    public mutating func lock(_ modifier: KeyModifiers) {
        switch modifier {
        case .ctrl: ctrl = .locked
        case .alt: alt = .locked
        case .shift: shift = .locked
        default: break
        }
    }

    /// Turns every modifier off.
    public mutating func reset() {
        self = ModifierLatch()
    }

    private static func advance(_ phase: inout LatchPhase, _ lastTap: inout TimeInterval, _ now: TimeInterval) {
        switch phase {
        case .off:
            phase = .oneShot
        case .oneShot:
            phase = (now - lastTap) <= doubleTapInterval ? .locked : .off
        case .locked:
            phase = .off
        }
        lastTap = now
    }
}
