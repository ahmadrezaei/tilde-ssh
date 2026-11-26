import Foundation
import SwiftTerm
import TildeCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Everything the SwiftUI side passes down on each update.
struct TerminalSurfaceInputs {
    var theme: TerminalTheme
    var environment: ServerEnvironment
    var keyBar: KeyBarConfiguration
    var appearance: TerminalAppearance
    var behavior: TerminalBehavior
    var snippets: any SnippetProviding
    var controller: TerminalController
    var onFontSizeChange: (Double) -> Void
    var onConfirmPaste: (@MainActor (PasteRequest) async -> Bool)?
    var onTitleChange: ((String) -> Void)?
}

/// Owns one SwiftTerm view and wires it to a `TerminalIO`: output stream to `feed`, typed input to `send`,
/// size changes to `resize`. It is also the view's delegate.
///
/// Hosts live in `TerminalHostRegistry`, keyed by session, so the screen content and scrollback survive when
/// SwiftUI tears down and rebuilds the surface (tab switches, iPhone session deck).
@MainActor
final class TerminalHost: TerminalViewDelegate {
    let view: TildeTerminalView
    private(set) weak var io: (any TerminalIO)?
    private var inputs: TerminalSurfaceInputs
    private var pump: Task<Void, Never>?
    private var pendingResize: (cols: Int, rows: Int)?
    private var isConfirmingLink = false
    fileprivate var attachCount = 0
    fileprivate var streamEnded = false
    fileprivate var registryKey: ObjectIdentifier?

    // What was applied last, to apply only differences on update.
    private var appliedTheme: TerminalTheme?
    private var appliedEnvironment: ServerEnvironment?
    private var appliedAppearance: TerminalAppearance?
    private var appliedParentFontSize: Double?
    private var appliedBehavior: TerminalBehavior?
    private var appliedKeyBar: KeyBarConfiguration?

    init(io: any TerminalIO, inputs: TerminalSurfaceInputs) {
        self.io = io
        self.inputs = inputs
        TerminalFonts.registerBundledFonts()
        view = TildeTerminalView(frame: .zero, font: TerminalFonts.font(inputs.appearance.font, size: inputs.appearance.fontSize))
        view.terminalDelegate = self
        view.pasteHandler = { [weak self] text in self?.handlePaste(text) }
        #if os(iOS)
        view.snippetHandler = { [weak self] command, run in self?.handleSnippet(command, run: run) }
        #endif
        view.onPinchEnded = { [weak self] in self?.flushPendingResize() }
        startPump(io)
        update(inputs)
    }

    deinit { pump?.cancel() }

    // MARK: Applying configuration

    func update(_ new: TerminalSurfaceInputs) {
        inputs = new
        let controller = new.controller
        view.bind(controller: controller)
        controller.fontSizeChanged = { [weak self] size in self?.inputs.onFontSizeChange(size) }

        if appliedTheme != new.theme || appliedEnvironment != new.environment {
            view.environment = new.environment
            view.applyTheme(new.theme, environment: new.environment)
            view.themeDidChange(new.theme)
            appliedTheme = new.theme
            appliedEnvironment = new.environment
        }

        let appearance = new.appearance
        let fontChanged = appliedAppearance?.font != appearance.font
        // A size from the parent applies when it differs from the last one the parent gave us. Pinch changes made
        // locally stay until the parent feeds a different value.
        let parentSizeChanged = appliedParentFontSize != appearance.fontSize
        if fontChanged || parentSizeChanged {
            let size = parentSizeChanged ? appearance.fontSize : controller.fontSize
            view.applyFont(appearance.font, size: size)
            controller.fontSize = TerminalAppearance.clamp(size)
            appliedParentFontSize = appearance.fontSize
        }
        if appliedAppearance?.cursorShape != appearance.cursorShape || appliedAppearance?.cursorBlink != appearance.cursorBlink {
            view.applyCursor(shape: appearance.cursorShape, blink: appearance.cursorBlink)
        }
        if appliedAppearance?.bell != appearance.bell { view.applyBell(appearance.bell) }
        appliedAppearance = appearance

        if appliedBehavior != new.behavior {
            if appliedBehavior?.scrollbackLines != new.behavior.scrollbackLines {
                view.changeScrollback(new.behavior.scrollbackLines)
            }
            view.applyBehavior(new.behavior)
            appliedBehavior = new.behavior
        }

        // The snippet source can change identity without the configuration changing, so always hand it over.
        view.snippets = new.snippets
        if appliedKeyBar != new.keyBar {
            view.configureKeyboard(new.keyBar)
            appliedKeyBar = new.keyBar
        }
    }

    // MARK: Output pump

    private func startPump(_ io: any TerminalIO) {
        let stream = io.output
        let feeder = view.feedSender
        pump = Task.detached(priority: .userInitiated) { [weak self] in
            for await chunk in stream {
                if Task.isCancelled { break }
                feeder.feed(byteArray: Array(chunk)[...])
            }
            await self?.outputEnded()
        }
    }

    private func outputEnded() {
        streamEnded = true
        if attachCount == 0 { TerminalHostRegistry.remove(self) }
    }

    // MARK: Paste guard

    private func handlePaste(_ text: String) {
        let needsConfirmation = inputs.behavior.pasteConfirmation.requiresConfirmation(for: inputs.environment)
        guard needsConfirmation, PasteRequest.isMultiLine(text) else {
            view.pasteText(text)
            return
        }
        confirm(PasteRequest(text: text, environment: inputs.environment)) { [weak self] in self?.view.pasteText(text) }
    }

    /// A snippet chosen from the key bar's palette. It is typed into the session like a paste, so a multi-line snippet
    /// asks first when the paste rules say so (always on PROD in the default mode). A one-line snippet never asks,
    /// with or without "run on insert" (the trailing Return is not a second line).
    func handleSnippet(_ command: String, run: Bool) {
        var bytes = Array(command.utf8)
        if run { bytes.append(0x0D) }
        guard !bytes.isEmpty else { return }
        let needsConfirmation = inputs.behavior.pasteConfirmation.requiresConfirmation(for: inputs.environment)
            && PasteRequest.hasMultipleLines(command)
        guard needsConfirmation else {
            view.sendInput(bytes)
            return
        }
        confirm(PasteRequest(text: command, environment: inputs.environment)) { [weak self] in self?.view.sendInput(bytes) }
    }

    /// Asks the user (through the session's sheet, or the view's own alert) and runs `approved` only on a yes.
    private func confirm(_ request: PasteRequest, approved perform: @escaping @MainActor () -> Void) {
        let confirm = inputs.onConfirmPaste
        let controller = inputs.controller
        controller.isPasteConfirmationPending = true
        Task { @MainActor [weak self] in
            let approved: Bool
            if let confirm {
                approved = await confirm(request)
            } else {
                approved = await self?.view.presentDefaultPasteConfirmation(request) ?? false
            }
            controller.isPasteConfirmationPending = false
            if approved { perform() }
        }
    }

    // MARK: TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        inputs.controller.size = (newCols, newRows)
        // While the fingers are down every pinch step changes the grid. Tell the server once, when the pinch ends.
        if view.isPinching {
            pendingResize = (newCols, newRows)
            return
        }
        pendingResize = nil
        sendResize(cols: newCols, rows: newRows)
    }

    private func sendResize(cols: Int, rows: Int) {
        let scale = view.currentBackingScale
        io?.resize(
            cols: cols, rows: rows,
            pixelWidth: Int(view.bounds.width * scale), pixelHeight: Int(view.bounds.height * scale)
        )
    }

    /// Sends the grid size that was held back during a pinch.
    func flushPendingResize() {
        guard let size = pendingResize else { return }
        pendingResize = nil
        sendResize(cols: size.cols, rows: size.rows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // The title is set by the remote program: strip control and bidi override characters, cap the length.
        let safe = TerminalSafety.sanitizedTitle(title)
        inputs.controller.title = safe.isEmpty ? nil : safe
        inputs.onTitleChange?(safe)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        #if os(macOS)
        // Keystrokes reach the session only from the visible tab with no question over it. Every tab's terminal stays
        // in the window, and AppKit can hand keyboard focus back to a hidden one (for example when a sheet closes).
        guard inputs.controller.acceptsKeyboardFocus else { return }
        #endif
        // Typed input can contain a password: never log it.
        io?.send(Data(data))
    }

    /// The emulator's own replies to the remote program, never gated.
    func reply(_ data: Data) { io?.send(data) }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func selectionFinished(source: TerminalView) {
        inputs.controller.hasSelection = source.selectionActive
    }

    func bell(source: TerminalView) { source.playDefaultBell() }

    // OSC 52: the remote program must not touch the clipboard unless the user opted in.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard inputs.behavior.osc52 != .off else { return }
        PlatformPasteboard.write(content)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        guard inputs.behavior.osc52 == .readWrite else { return nil }
        return PlatformPasteboard.readData()
    }

    /// Links in terminal output are untrusted. Only http, https and ssh links are considered, and every one is
    /// confirmed with its full URL before anything opens (an OSC 8 link can hide its target behind other text).
    func requestOpenLink(source: TerminalView, request: TerminalLinkRequest) {
        guard let url = TerminalSafety.openableURL(for: request.link), !isConfirmingLink else { return }
        isConfirmingLink = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let approved = await self.view.presentLinkConfirmation(url)
            self.isConfirmingLink = false
            if approved { self.view.openExternally(url) }
        }
    }

    // MARK: Lifecycle

    func didAttach() { attachCount += 1 }

    func didDetach() {
        attachCount = max(0, attachCount - 1)
        if attachCount == 0, streamEnded { TerminalHostRegistry.remove(self) }
    }
}

/// Keeps one `TerminalHost` per session alive for as long as the session exists.
@MainActor
enum TerminalHostRegistry {
    private static var hosts: [ObjectIdentifier: TerminalHost] = [:]

    static func host(for io: any TerminalIO, inputs: @autoclosure () -> TerminalSurfaceInputs) -> TerminalHost {
        // Entries whose session is gone have nothing left to show.
        for (key, host) in hosts where host.io == nil { hosts[key] = nil }
        let key = ObjectIdentifier(io)
        if let existing = hosts[key] { return existing }
        let host = TerminalHost(io: io, inputs: inputs())
        host.registryKey = key
        hosts[key] = host
        return host
    }

    static func remove(_ host: TerminalHost) {
        if let key = host.registryKey, hosts[key] === host { hosts[key] = nil }
    }
}

/// Pasteboard access shared by both platforms (OSC 52 policy).
enum PlatformPasteboard {
    @MainActor static func write(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    @MainActor static func readData() -> Data? {
        #if canImport(UIKit)
        UIPasteboard.general.string.map { Data($0.utf8) }
        #else
        NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
        #endif
    }

    @MainActor static func readString() -> String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}
