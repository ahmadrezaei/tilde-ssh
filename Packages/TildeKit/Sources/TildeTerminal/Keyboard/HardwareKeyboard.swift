import Foundation
@preconcurrency import GameController
import Observation

/// Watches for a hardware keyboard (`GCKeyboard`). The key bar shrinks to a slim strip, or hides, while one is attached.
@MainActor
@Observable
public final class HardwareKeyboardMonitor {
    /// A shared monitor; observers are installed on first use.
    public static let shared = HardwareKeyboardMonitor()

    /// Whether a hardware keyboard is connected (or `overrideAttached`, when set).
    public var isAttached: Bool {
        #if DEBUG
        overrideAttached ?? detectedAttached
        #else
        detectedAttached
        #endif
    }

    #if DEBUG
    /// Pretends a keyboard is (or is not) attached. Debug builds only, for demos and tests: the iOS Simulator
    /// always reports the Mac's keyboard, which would otherwise keep the key bar in its slim strip form.
    public var overrideAttached: Bool? {
        didSet { for callback in onChange.values { callback() } }
    }
    #endif

    private var detectedAttached: Bool

    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored var onChange: [UUID: () -> Void] = [:]

    public init() {
        detectedAttached = GCKeyboard.coalesced != nil
        let center = NotificationCenter.default
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    isolated deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    private func refresh() {
        let attached = GCKeyboard.coalesced != nil
        guard attached != detectedAttached else { return }
        detectedAttached = attached
        for callback in onChange.values { callback() }
    }

    /// Registers a callback for attach/detach; returns a token to pass to `removeObserver`.
    func addObserver(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        onChange[id] = callback
        return id
    }

    func removeObserver(_ id: UUID) { onChange[id] = nil }
}

/// What the key bar looks like for the current keyboard situation.
enum KeyBarStyle: Equatable {
    /// Full bar (iPhone: pages + joystick; iPad: one wide row).
    case full
    /// Esc, F-keys, snippets and Ctrl lock for use with a hardware keyboard.
    case slim
    /// No accessory view.
    case hidden

    static func resolve(hardwareKeyboardAttached: Bool, mode: HardwareKeyboardMode) -> KeyBarStyle {
        guard hardwareKeyboardAttached else { return .full }
        switch mode {
        case .slimStrip: return .slim
        case .hidden: return .hidden
        }
    }
}
