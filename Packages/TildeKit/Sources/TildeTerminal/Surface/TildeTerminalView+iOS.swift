#if os(iOS)
import SwiftTerm
import SwiftUI
import TildeCore
import UIKit

/// SwiftTerm's UIKit `TerminalView` with Tilde's input rules: the key bar replaces SwiftTerm's accessory,
/// sticky modifiers apply to the next software or hardware key, hardware keys SwiftTerm does not send (F12 and up,
/// Insert) are mapped, Cmd-period sends Esc, and pinch changes the font size.
@MainActor
final class TildeTerminalView: TerminalView, TerminalViewActions, KeyBarViewDelegate, UIGestureRecognizerDelegate {
    /// Receives pasted text instead of the view pasting it directly (the host applies the paste guard).
    var pasteHandler: ((String) -> Void)?
    var environment: ServerEnvironment = .none
    var snippets: (any SnippetProviding)?

    private weak var controller: TerminalController?
    private var keyboardConfiguration = KeyBarConfiguration.default
    private var keyBar: KeyBarView?
    private var hardwareObserver: UUID?
    private var didSetUp = false
    private var pinchStartSize: Double = 13
    private var palette: SnippetPalettePresenter?
    private var resignObserver: (any NSObjectProtocol)?

    /// True while a pinch gesture changes the font size (the host holds back remote resizes until it ends).
    private(set) var isPinching = false
    var onPinchEnded: (() -> Void)?

    var inputState: TerminalInputState? { controller?.inputState }

    func bind(controller: TerminalController) {
        if self.controller !== controller {
            self.controller?.inputState.onChange = nil
            self.controller = controller
        }
        controller.actions = self
        controller.inputState.onChange = { [weak self] in self?.keyBar?.refreshModifiers() }
        keyBar?.inputState = controller.inputState
    }

    // MARK: Setup

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            // Drop what would keep this view reachable from shared singletons.
            if let hardwareObserver {
                HardwareKeyboardMonitor.shared.removeObserver(hardwareObserver)
                self.hardwareObserver = nil
            }
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
            inputState?.reset()
            return
        }
        if !didSetUp {
            didSetUp = true
            keyboardDismissMode = .interactive
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            addGestureRecognizer(pinch)
            // Open on the keyboard: "tap a server and you are typing".
            DispatchQueue.main.async { [weak self] in _ = self?.becomeFirstResponder() }
        }
        if hardwareObserver == nil {
            hardwareObserver = HardwareKeyboardMonitor.shared.addObserver { [weak self] in self?.updateAccessory() }
        }
        if resignObserver == nil {
            // An armed Ctrl must not survive switching away from the app.
            let box = WeakViewBox(self)
            resignObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { box.view?.inputState?.reset() }
            }
        }
        updateAccessory()
    }

    override func resignFirstResponder() -> Bool {
        inputState?.reset()
        return super.resignFirstResponder()
    }

    func configureKeyboard(_ configuration: KeyBarConfiguration) {
        keyboardConfiguration = configuration
        optionAsMetaKey = configuration.optionAsMeta
        keyBar?.configuration = configuration
        updateAccessory()
    }

    private func updateAccessory() {
        let style = KeyBarStyle.resolve(
            hardwareKeyboardAttached: HardwareKeyboardMonitor.shared.isAttached,
            mode: keyboardConfiguration.hardwareKeyboardMode
        )
        if style == .hidden {
            if inputAccessoryView != nil {
                inputAccessoryView = nil
                reloadInputViews()
            }
            return
        }
        let bar: KeyBarView
        if let existing = keyBar {
            bar = existing
        } else {
            bar = KeyBarView(configuration: keyboardConfiguration)
            bar.delegate = self
            if let state = controller?.inputState { bar.inputState = state }
            keyBar = bar
        }
        bar.style = style
        if inputAccessoryView !== bar {
            inputAccessoryView = bar
            reloadInputViews()
        }
    }

    // MARK: Gestures

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let controller else { return }
        switch gesture.state {
        case .began:
            isPinching = true
            pinchStartSize = controller.fontSize
        case .changed:
            // Half-point steps keep the layout work down while the fingers move.
            let size = (pinchStartSize * Double(gesture.scale) * 2).rounded() / 2
            controller.setFontSize(size)
        case .ended, .cancelled, .failed:
            isPinching = false
            onPinchEnded?()
        default:
            break
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    // MARK: Paste guard

    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        if let pasteHandler { pasteHandler(text) } else { pasteText(text) }
    }

    func presentDefaultPasteConfirmation(_ request: PasteRequest) async -> Bool {
        guard let presenter = window?.rootViewController?.topmostPresented else { return false }
        let prod = request.environment == .prod
        let alert = UIAlertController(
            title: "Paste \(request.lineCount) lines\(prod ? " into a PRODUCTION server" : "")?",
            message: request.preview.joined(separator: "\n") + (request.lineCount > request.preview.count ? "\n…" : ""),
            preferredStyle: .alert
        )
        return await withCheckedContinuation { continuation in
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Paste", style: prod ? .destructive : .default) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
    }

    // MARK: Software keyboard input with sticky modifiers

    override func insertText(_ text: String) {
        if let state = inputState, !state.active.isEmpty, !text.isEmpty {
            let modifiers = state.consume()
            if text == "\n" {
                sendInput(InputMapper.bytes(for: .enter, modifiers: modifiers, modes: currentModes))
            } else {
                sendInput(InputMapper.bytes(forText: text, modifiers: modifiers))
            }
            return
        }
        super.insertText(text)
    }

    override func deleteBackward() {
        if let state = inputState, !state.active.isEmpty {
            sendInput(InputMapper.bytes(for: .backspace, modifiers: state.consume(), modes: currentModes))
            return
        }
        super.deleteBackward()
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var remaining = presses
        for press in presses {
            guard let key = press.key, let named = Self.namedKey(for: key.keyCode) else { continue }
            let flags = key.modifierFlags
            if flags.contains(.command) { continue }
            // SwiftTerm covers unmodified arrows, Home/End, paging and F1-F11 (with key repeat). Take over only
            // when a sticky modifier is armed, or for keys SwiftTerm ignores (F12 and up, Insert).
            let stickyArmed = !(inputState?.active.isEmpty ?? true)
            guard stickyArmed || named.functionNumber.map({ $0 >= 12 }) == true || named == .insert else { continue }
            var modifiers: KeyModifiers = inputState?.consume() ?? []
            if flags.contains(.control) { modifiers.insert(.ctrl) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.alternate), keyboardConfiguration.optionAsMeta { modifiers.insert(.alt) }
            sendInput(InputMapper.bytes(for: named, modifiers: modifiers, modes: currentModes))
            remaining.remove(press)
        }
        // A sticky modifier is spent by the next key, also when that key brings its own hardware modifier
        // (SwiftTerm sends those itself). Pure modifier presses do not count.
        if let state = inputState, !state.active.isEmpty {
            for press in remaining {
                guard let key = press.key, !Self.isModifierKey(key.keyCode), !key.modifierFlags.contains(.command) else { continue }
                if !key.modifierFlags.isDisjoint(with: [.control, .alternate]) {
                    _ = state.consume()
                    break
                }
            }
        }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    private static func isModifierKey(_ code: UIKeyboardHIDUsage) -> Bool {
        switch code {
        case .keyboardLeftControl, .keyboardRightControl, .keyboardLeftShift, .keyboardRightShift,
             .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI,
             .keyboardCapsLock, .keyboardLockingCapsLock:
            return true
        default:
            return false
        }
    }

    private static func namedKey(for code: UIKeyboardHIDUsage) -> NamedKey? {
        switch code {
        case .keyboardUpArrow: .up
        case .keyboardDownArrow: .down
        case .keyboardLeftArrow: .left
        case .keyboardRightArrow: .right
        case .keyboardHome: .home
        case .keyboardEnd: .end
        case .keyboardPageUp: .pageUp
        case .keyboardPageDown: .pageDown
        case .keyboardDeleteForward: .delete
        case .keyboardInsert: .insert
        case .keyboardEscape: .escape
        case .keyboardTab: .tab
        case .keyboardF1: .f1
        case .keyboardF2: .f2
        case .keyboardF3: .f3
        case .keyboardF4: .f4
        case .keyboardF5: .f5
        case .keyboardF6: .f6
        case .keyboardF7: .f7
        case .keyboardF8: .f8
        case .keyboardF9: .f9
        case .keyboardF10: .f10
        case .keyboardF11: .f11
        case .keyboardF12: .f12
        case .keyboardF13: .f13
        case .keyboardF14: .f14
        case .keyboardF15: .f15
        case .keyboardF16: .f16
        case .keyboardF17: .f17
        case .keyboardF18: .f18
        case .keyboardF19: .f19
        case .keyboardF20: .f20
        case .keyboardF21: .f21
        case .keyboardF22: .f22
        case .keyboardF23: .f23
        case .keyboardF24: .f24
        default: nil
        }
    }

    /// Cmd-period = Esc (the Magic Keyboard for iPad has no Esc key). Find, clear and font size are driven by
    /// the app's menu through `TerminalController`, so they are not registered here.
    override var keyCommands: [UIKeyCommand]? {
        guard keyboardConfiguration.commandPeriodSendsEscape else { return nil }
        let command = UIKeyCommand(title: "Send Escape", action: #selector(keyEscape), input: ".", modifierFlags: .command)
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    @objc private func keyEscape() { sendInput([0x1B]) }

    // MARK: Key bar actions

    private var currentModes: TerminalInputModes {
        TerminalInputModes(
            applicationCursor: terminalInputStateSnapshot()?.applicationCursor ?? false,
            backspaceSendsControlH: backspaceSendsControlH
        )
    }

    func keyBar(_ bar: KeyBarView, perform action: KeyAction) {
        switch action.kind {
        case .text:
            let modifiers = inputState?.consume() ?? []
            sendInput(InputMapper.bytes(forText: action.value, modifiers: modifiers))
        case .key:
            if let key = action.namedKey { sendKey(key, modifiers: action.modifiers) }
        case .ctrl:
            let modifiers = (inputState?.consume() ?? []).union(.ctrl)
            sendInput(InputMapper.bytes(forText: action.value, modifiers: modifiers))
        case .modifier:
            if let modifier = action.stickyModifier { inputState?.tap(modifier) }
        case .snippets:
            break   // handled through keyBarRequestsSnippets(from:)
        case .tmuxPrefix:
            let modifiers = (inputState?.consume() ?? []).union(.ctrl)
            sendInput(InputMapper.bytes(forText: keyboardConfiguration.layout.tmuxPrefix, modifiers: modifiers))
        case .paste:
            paste(nil)
        case .hideKeyboard:
            _ = resignFirstResponder()
        }
    }

    func keyBarRequestsSnippets(_ bar: KeyBarView, from source: UIView) {
        guard let snippets else { return }
        let presenter = palette ?? SnippetPalettePresenter()
        palette = presenter
        presenter.present(from: source, snippets: snippets) { [weak self] command, run in
            guard let self else { return }
            var bytes = Array(command.utf8)
            if run { bytes.append(0x0D) }
            self.sendInput(bytes)
            _ = self.becomeFirstResponder()
        }
    }

    func keyBarHapticsEnabled(_ bar: KeyBarView) -> Bool { keyboardConfiguration.hapticsEnabled }

    func keyBarPopoverWindow(_ bar: KeyBarView) -> UIWindow? { window }

    /// Called after a theme change: the key bar follows the terminal's light or dark look.
    func themeDidChange(_ theme: TerminalTheme) {
        keyBar?.overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        reloadInputViews()
    }

    // MARK: TerminalViewActions

    func applyFontSize(_ size: Double) { font = font.withSize(CGFloat(size)) }

    func showFindBar() { controller?.isFindPresented = true }

    func findNext(_ query: String, caseSensitive: Bool, forward: Bool) -> Bool {
        let options = SearchOptions(caseSensitive: caseSensitive)
        return forward ? findNext(query, options: options) : findPrevious(query, options: options)
    }

    func matchSummary(_ query: String, caseSensitive: Bool) -> (index: Int, total: Int) {
        searchMatchSummary(query, options: SearchOptions(caseSensitive: caseSensitive))
    }

    func clearFindHighlights() { clearSearch() }

    func stepFind(forward: Bool) { controller?.stepFindInQuery(forward: forward) }

    func discardScrollback() { clearScrollback() }

    func clearScreen() {
        clearScrollback()
        if terminalInputStateSnapshot()?.isAlternateBuffer != true { sendInput([0x0C]) }   // ask the shell to redraw its prompt
    }

    func copySelection() { copy(self) }
    func pasteClipboard() { paste(self) }
    func selectAllText() { selectAll(nil) }

    func sendInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        send(data: bytes[...])
    }

    func sendKey(_ key: NamedKey, modifiers: KeyModifiers) {
        let applied = modifiers.union(inputState?.consume() ?? [])
        if key == .backspace, applied.isEmpty {
            // SwiftTerm knows whether the application set DECBKM (backspace sends ^H); its own path honours it.
            super.deleteBackward()
            return
        }
        sendInput(InputMapper.bytes(for: key, modifiers: applied, modes: currentModes))
    }

    func focusTerminal() { _ = becomeFirstResponder() }
    func scrollToEnd() { scroll(toPosition: 1) }
}

/// Lets a notification closure (which UIKit marks Sendable but runs on the main queue) reach the view.
final class WeakViewBox: @unchecked Sendable {
    weak var view: TildeTerminalView?
    init(_ view: TildeTerminalView) { self.view = view }
}

extension TildeTerminalView {
    /// Asks before opening a link from terminal output, showing the complete URL.
    func presentLinkConfirmation(_ url: URL) async -> Bool {
        guard let presenter = window?.rootViewController?.topmostPresented else { return false }
        let alert = UIAlertController(
            title: "Open link?",
            message: "The terminal asked to open:\n\n\(url.absoluteString)",
            preferredStyle: .alert
        )
        return await withCheckedContinuation { continuation in
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
    }

    func openExternally(_ url: URL) { UIApplication.shared.open(url) }
}

extension UIViewController {
    /// The view controller at the top of the presentation stack, for alerts and popovers.
    var topmostPresented: UIViewController {
        var top = self
        while let next = top.presentedViewController { top = next }
        return top
    }
}
#endif
