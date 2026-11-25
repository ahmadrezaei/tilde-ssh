import Foundation
import Observation

/// Sticky modifier state shared by the key bar, the terminal view and the modifier HUD.
@MainActor
@Observable
final class TerminalInputState {
    private(set) var latch = ModifierLatch()
    /// Called after any change, for UIKit views that cannot use Observation.
    @ObservationIgnored var onChange: (() -> Void)?

    var active: KeyModifiers { latch.active }

    /// `CTRL`, `CTRL 🔒`, `CTRL+ALT`; nil when nothing is armed.
    var hudText: String? {
        guard !latch.isIdle else { return nil }
        var parts: [String] = []
        for (modifier, name) in [(KeyModifiers.ctrl, "CTRL"), (.alt, "ALT"), (.shift, "SHIFT")] {
            switch latch.phase(of: modifier) {
            case .off: break
            case .oneShot: parts.append(name)
            case .locked: parts.append(name + " 🔒")
            }
        }
        return parts.joined(separator: "+")
    }

    func tap(_ modifier: KeyModifiers) {
        latch.tap(modifier, now: ProcessInfo.processInfo.systemUptime)
        onChange?()
    }

    func lock(_ modifier: KeyModifiers) {
        latch.lock(modifier)
        onChange?()
    }

    /// Modifiers for the key being sent; clears one-shot modifiers.
    func consume() -> KeyModifiers {
        guard !latch.isIdle else { return [] }
        let applied = latch.consume()
        onChange?()
        return applied
    }

    func reset() {
        guard !latch.isIdle else { return }
        latch.reset()
        onChange?()
    }
}

/// What a platform terminal view can do on behalf of `TerminalController`.
@MainActor
protocol TerminalViewActions: AnyObject {
    func applyFontSize(_ size: Double)
    func showFindBar()
    func findNext(_ query: String, caseSensitive: Bool, forward: Bool) -> Bool
    func matchSummary(_ query: String, caseSensitive: Bool) -> (index: Int, total: Int)
    func clearFindHighlights()
    func stepFind(forward: Bool)
    func clearScreen()
    func discardScrollback()
    func copySelection()
    func pasteClipboard()
    func selectAllText()
    func sendInput(_ bytes: [UInt8])
    func sendKey(_ key: NamedKey, modifiers: KeyModifiers)
    func focusTerminal()
    func scrollToEnd()
}

/// A handle on one terminal, for the screens around it: the Mac menu bar (Copy, Paste, Find, Clear, font size),
/// the session menu on iOS (Find, Font size) and anything that needs the terminal's live state.
///
/// Create one per session, pass it to `TerminalSurface(controller:)` and keep it next to the session. Without
/// one the surface works but nobody else can drive it.
@MainActor
@Observable
public final class TerminalController {
    /// Current font size in points (follows pinch and Cmd +/-).
    public internal(set) var fontSize: Double = 13
    /// The title the remote program set (OSC 0/2), if any.
    public internal(set) var title: String?
    /// Terminal size in cells, `nil` before the first layout.
    public internal(set) var size: (cols: Int, rows: Int)?
    /// Whether the iOS find bar is showing. On macOS the built-in find bar is used and this stays false.
    public var isFindPresented = false
    public var findQuery = ""
    public var findCaseSensitive = false
    /// "2/14", "No results" or empty.
    public internal(set) var findStatus = ""
    /// Transient "13 pt" label shown while the font size changes.
    public internal(set) var fontSizeHUD: String?
    /// Whether the terminal has a selection that Copy would use.
    public internal(set) var hasSelection = false
    /// The server environment is PROD and a confirmation is currently showing: used by overlays.
    public internal(set) var isPasteConfirmationPending = false

    let inputState = TerminalInputState()
    @ObservationIgnored weak var actions: (any TerminalViewActions)?
    @ObservationIgnored var fontSizeChanged: ((Double) -> Void)?
    @ObservationIgnored private var hudTask: Task<Void, Never>?

    public init() {}

    /// `CTRL`, `CTRL 🔒`, `CTRL+ALT` while sticky modifiers are armed (the HUD chip), else nil.
    public var modifierHUDText: String? { inputState.hudText }

    // MARK: Font size

    /// Sets the font size, clamped to 9...32 pt.
    public func setFontSize(_ size: Double) {
        let clamped = TerminalAppearance.clamp(size)
        guard clamped != fontSize else { return }
        fontSize = clamped
        actions?.applyFontSize(clamped)
        fontSizeChanged?(clamped)
        flashFontSizeHUD()
    }

    public func increaseFontSize() { setFontSize(fontSize + 1) }
    public func decreaseFontSize() { setFontSize(fontSize - 1) }

    /// Back to the platform default (12 pt on iPhone, 13 pt elsewhere).
    public func resetFontSize() {
        #if os(iOS)
        setFontSize(TerminalAppearance.platformDefaultFontSize)
        #else
        setFontSize(13)
        #endif
    }

    func flashFontSizeHUD() {
        fontSizeHUD = "\(Int(fontSize.rounded())) pt"
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.fontSizeHUD = nil
        }
    }

    // MARK: Find

    /// Shows the find bar (Cmd+F).
    public func showFind() {
        #if os(macOS)
        actions?.showFindBar()
        #else
        isFindPresented = true
        #endif
    }

    public func hideFind() {
        isFindPresented = false
        findStatus = ""
        actions?.clearFindHighlights()
        actions?.focusTerminal()
    }

    /// Finds the next match (Cmd+G). On macOS this steps SwiftTerm's own find bar; on iOS it searches `findQuery`.
    public func findNext() { findNext(forward: true) }

    /// Finds the previous match (Cmd+Shift+G).
    public func findPrevious() { findNext(forward: false) }

    /// Finds the next (or previous) match of `findQuery`.
    public func findNext(forward: Bool) {
        #if os(macOS)
        actions?.stepFind(forward: forward)
        return
        #else
        stepFindInQuery(forward: forward)
        #endif
    }

    func stepFindInQuery(forward: Bool) {
        guard !findQuery.isEmpty else {
            findStatus = ""
            actions?.clearFindHighlights()
            return
        }
        let found = actions?.findNext(findQuery, caseSensitive: findCaseSensitive, forward: forward) ?? false
        if found, let summary = actions?.matchSummary(findQuery, caseSensitive: findCaseSensitive), summary.total > 0 {
            findStatus = summary.index > 0 ? "\(summary.index)/\(summary.total)" : "\(summary.total) matches"
        } else {
            findStatus = "No results"
        }
    }

    // MARK: Editing and screen

    /// Clears the screen and scrollback and asks the shell to redraw its prompt (Cmd+K).
    public func clear() { actions?.clearScreen() }

    /// Discards the scrollback history but leaves the visible screen alone.
    public func clearScrollback() { actions?.discardScrollback() }

    /// Sends Ctrl-C (interrupt) to the foreground program.
    public func sendInterrupt() { actions?.sendInput([0x03]) }
    public func copy() { actions?.copySelection() }
    public func paste() { actions?.pasteClipboard() }
    public func selectAll() { actions?.selectAllText() }
    public func scrollToBottom() { actions?.scrollToEnd() }
    /// Gives the terminal keyboard focus.
    public func focus() { actions?.focusTerminal() }

    // MARK: Sending

    /// Types `text` into the terminal as if the user had entered it.
    public func sendText(_ text: String) { actions?.sendInput(Array(text.utf8)) }

    /// Sends a key, honouring DECCKM-aware arrows and any armed sticky modifiers.
    public func sendKey(_ key: NamedKey, modifiers: KeyModifiers = []) {
        actions?.sendKey(key, modifiers: modifiers)
    }
}
