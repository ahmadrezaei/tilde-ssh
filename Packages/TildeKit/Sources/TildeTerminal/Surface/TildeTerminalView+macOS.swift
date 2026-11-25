#if os(macOS)
import AppKit
import SwiftTerm
import TildeCore

/// SwiftTerm's AppKit `TerminalView` plus Tilde's keyboard rules: Option as Meta, Cmd-period = Esc, Cmd-K clears,
/// Cmd +/-/0 change the font size, and the multi-line paste guard. There is no key bar on the Mac.
@MainActor
final class TildeTerminalView: TerminalView, TerminalViewActions {
    /// Receives pasted text instead of the view pasting it directly (the host applies the paste guard).
    var pasteHandler: ((String) -> Void)?
    var environment: ServerEnvironment = .none
    var snippets: (any SnippetProviding)?
    private weak var controller: TerminalController?
    private var keyboardConfiguration = KeyBarConfiguration.default

    func bind(controller: TerminalController) {
        self.controller = controller
        controller.actions = self
    }

    func themeDidChange(_ theme: TerminalTheme) {}

    func configureKeyboard(_ configuration: KeyBarConfiguration) {
        keyboardConfiguration = configuration
        optionAsMetaKey = configuration.optionAsMeta
    }

    // MARK: Paste guard

    @objc override func paste(_ sender: Any) {
        guard let text = PlatformPasteboard.readString(), !text.isEmpty else { return }
        if let pasteHandler { pasteHandler(text) } else { pasteText(text) }
    }

    func presentDefaultPasteConfirmation(_ request: PasteRequest) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = request.environment == .prod ? .critical : .warning
        alert.messageText = "Paste \(request.lineCount) lines\(request.environment == .prod ? " into a PRODUCTION server" : "")?"
        alert.informativeText = request.preview.joined(separator: "\n") + (request.lineCount > request.preview.count ? "\n…" : "")
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    // MARK: Shortcuts

    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard window != nil else { return }
        // `performKeyEquivalent` is not open in SwiftTerm, so shortcuts are caught with a local monitor while this
        // terminal has keyboard focus. Menu bar commands for the same keys keep working when the terminal is not focused.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // The monitor runs on the main thread; NSEvent is simply not marked Sendable.
            nonisolated(unsafe) let unsafeEvent = event
            let handled = MainActor.assumeIsolated { self.handleShortcut(unsafeEvent) }
            return handled ? nil : event
        }
    }

    /// Cmd-period = Esc, Cmd-K clears, Cmd +/-/0 change the font size. Returns true when handled.
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard let window, window.firstResponder === self, window.isKeyWindow else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let key = event.charactersIgnoringModifiers else { return false }
        let plain = flags == .command
        switch key {
        case "." where plain && keyboardConfiguration.commandPeriodSendsEscape:
            sendInput([0x1B])
        case "k" where plain:
            controller?.clear()
        case "+" where plain || flags == [.command, .shift], "=" where plain:
            controller?.increaseFontSize()
        case "-" where plain:
            controller?.decreaseFontSize()
        case "0" where plain:
            controller?.resetFontSize()
        default:
            return false
        }
        return true
    }

    // MARK: TerminalViewActions

    func applyFontSize(_ size: Double) {
        font = NSFont(descriptor: font.fontDescriptor, size: CGFloat(size)) ?? font
    }

    func showFindBar() {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        performFindPanelAction(item)
    }

    func findNext(_ query: String, caseSensitive: Bool, forward: Bool) -> Bool {
        let options = SearchOptions(caseSensitive: caseSensitive)
        return forward ? findNext(query, options: options) : findPrevious(query, options: options)
    }

    func matchSummary(_ query: String, caseSensitive: Bool) -> (index: Int, total: Int) {
        searchMatchSummary(query, options: SearchOptions(caseSensitive: caseSensitive))
    }

    func clearFindHighlights() { clearSearch() }

    func clearScreen() {
        clearScrollback()
        if terminalInputStateSnapshot()?.isAlternateBuffer != true { sendInput([0x0C]) }   // ask the shell to redraw its prompt
    }

    func copySelection() { copy(self) }
    func pasteClipboard() { paste(self) }
    func selectAllText() { selectAll(nil) }

    func sendInput(_ bytes: [UInt8]) { send(data: bytes[...]) }

    func sendKey(_ key: NamedKey, modifiers: KeyModifiers) {
        let modes = TerminalInputModes(applicationCursor: terminalInputStateSnapshot()?.applicationCursor ?? false)
        sendInput(InputMapper.bytes(for: key, modifiers: modifiers, modes: modes))
    }

    func focusTerminal() { window?.makeFirstResponder(self) }
    func scrollToEnd() { scroll(toPosition: 1) }
}
#endif
