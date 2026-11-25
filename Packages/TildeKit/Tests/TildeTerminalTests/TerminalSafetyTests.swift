import Foundation
import Synchronization
import Testing
import TildeCore
@testable import TildeTerminal

@Suite struct TitleSanitizerTests {
    @Test func plainTitlePassesThrough() {
        #expect(TerminalSafety.sanitizedTitle("deploy@prod-api-01: ~/src") == "deploy@prod-api-01: ~/src")
        #expect(TerminalSafety.sanitizedTitle("日本語 – ñ 🚀") == "日本語 – ñ 🚀")
    }

    @Test func controlCharactersAreStripped() {
        #expect(TerminalSafety.sanitizedTitle("a\u{07}b\u{1B}[31mc\nd\re\tf\u{7F}g") == "ab[31mcdefg")
        #expect(TerminalSafety.sanitizedTitle("x\u{85}y\u{2028}z\u{2029}") == "xyz")   // C1 NEL, line and paragraph separators
    }

    @Test func bidiOverridesAreStripped() {
        // "invoice\u{202E}fdp.exe" would render as "invoiceexe.pdf".
        #expect(TerminalSafety.sanitizedTitle("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        for scalar in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F, 0x061C] {
            let title = "a\(String(UnicodeScalar(scalar)!))b"
            #expect(TerminalSafety.sanitizedTitle(title) == "ab", "U+\(String(scalar, radix: 16))")
        }
    }

    @Test func titleIsTrimmedAndTruncatedTo128() {
        #expect(TerminalSafety.sanitizedTitle("   padded  ") == "padded")
        let long = String(repeating: "x", count: 500)
        #expect(TerminalSafety.sanitizedTitle(long).count == 128)
        let emoji = String(repeating: "🚀", count: 300)
        #expect(TerminalSafety.sanitizedTitle(emoji).count == 128)
        #expect(TerminalSafety.sanitizedTitle("\u{1B}\u{07}").isEmpty)
    }
}

@Suite struct LinkSchemeTests {
    @Test func webAndSSHLinksAreAllowed() {
        #expect(TerminalSafety.openableURL(for: "https://example.com/a?b=c")?.absoluteString == "https://example.com/a?b=c")
        #expect(TerminalSafety.openableURL(for: "http://10.0.0.1:8080/")?.host == "10.0.0.1")
        #expect(TerminalSafety.openableURL(for: "ssh://deploy@db.internal:2222")?.scheme == "ssh")
        #expect(TerminalSafety.openableURL(for: "HTTPS://Example.com")?.scheme?.lowercased() == "https")
    }

    @Test func otherSchemesAreRejected() {
        for link in [
            "file:///etc/passwd", "javascript:alert(1)", "tel:+15551234", "mailto:a@b.c", "sms:123", "x-apple-reminderkit://",
            "tilde://open", "data:text/html,hi", "ftp://example.com", "itms-services://?action=download-manifest&url=https://x",
        ] {
            #expect(TerminalSafety.openableURL(for: link) == nil, "\(link)")
        }
    }

    @Test func relativeAndMalformedLinksAreRejected() {
        for link in ["", "   ", "./README.md", "/usr/bin/env", "example.com", "src/main.swift:12:3", "https://", "http:///nohost", "https://exa\u{07}mple.com"] {
            #expect(TerminalSafety.openableURL(for: link) == nil, "\(link)")
        }
    }
}

#if os(macOS)
import AppKit

/// Records what the terminal sends to the "server".
final class RecordingIO: TerminalIO {
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let sent = Mutex<[UInt8]>([])
    private let sizes = Mutex<[(Int, Int)]>([])

    init() {
        var c: AsyncStream<Data>.Continuation!
        output = AsyncStream { c = $0 }
        continuation = c
    }

    func send(_ bytes: Data) { sent.withLock { $0.append(contentsOf: bytes) } }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) { sizes.withLock { $0.append((cols, rows)) } }

    func emit(_ text: String) { continuation.yield(Data(text.utf8)) }
    var sentBytes: [UInt8] { sent.withLock { $0 } }
    func clearSent() { sent.withLock { $0.removeAll() } }
}

/// Feeds real escape sequences into a real SwiftTerm view and checks what the keys send back.
@MainActor
@Suite struct TerminalHostInputTests {
    private func makeHost(_ io: RecordingIO) -> (TerminalHost, TerminalController) {
        let controller = TerminalController()
        let inputs = TerminalSurfaceInputs(
            theme: .tildeNight, environment: .none, keyBar: .default, appearance: TerminalAppearance(),
            behavior: .default, snippets: StaticSnippetProvider(), controller: controller,
            onFontSizeChange: { _ in }, onConfirmPaste: nil, onTitleChange: nil
        )
        let host = TerminalHost(io: io, inputs: inputs)
        host.view.frame = CGRect(x: 0, y: 0, width: 640, height: 400)
        return (host, controller)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func applicationCursorModeChangesArrowSequence() async throws {
        let io = RecordingIO()
        let (host, controller) = makeHost(io)

        // Normal mode: CSI A.
        controller.sendKey(.up)
        #expect(await waitUntil { io.sentBytes == [0x1B, 0x5B, 0x41] })
        io.clearSent()

        // The program turns DECCKM on: ESC [ ? 1 h. Arrows must now be SS3 (ESC O A).
        io.emit("\u{1B}[?1h")
        #expect(await waitUntil { host.view.terminalInputStateSnapshot()?.applicationCursor == true })
        controller.sendKey(.up)
        #expect(await waitUntil { io.sentBytes == [0x1B, 0x4F, 0x41] })
        io.clearSent()

        // Modified arrows keep the CSI 1 ; m form in application mode.
        controller.sendKey(.left, modifiers: .ctrl)
        #expect(await waitUntil { io.sentBytes == Array("\u{1B}[1;5D".utf8) })
        io.clearSent()

        // DECCKM off again: back to CSI.
        io.emit("\u{1B}[?1l")
        #expect(await waitUntil { host.view.terminalInputStateSnapshot()?.applicationCursor == false })
        controller.sendKey(.down)
        #expect(await waitUntil { io.sentBytes == [0x1B, 0x5B, 0x42] })
    }

    @Test func stickyCtrlAppliesToControllerKeysAndIsSpent() async throws {
        let io = RecordingIO()
        let (host, controller) = makeHost(io)
        defer { withExtendedLifetime(host) {} }
        controller.inputState.tap(.ctrl)
        controller.sendKey(.up)
        #expect(await waitUntil { io.sentBytes == Array("\u{1B}[1;5A".utf8) })
        #expect(controller.inputState.active.isEmpty)
    }

    @Test func titleFromRemoteIsSanitized() async throws {
        let io = RecordingIO()
        let (host, controller) = makeHost(io)
        defer { withExtendedLifetime(host) {} }
        io.emit("\u{1B}]0;ev\u{202E}il title\u{07}")
        #expect(await waitUntil { controller.title != nil })
        #expect(controller.title == "evil title")
    }

    @Test func controllerPassedToSurfaceIsTheOneThatDrivesTheTerminal() async throws {
        let io = RecordingIO()
        let (host, controller) = makeHost(io)
        defer { withExtendedLifetime(host) {} }
        controller.sendText("ls")
        #expect(await waitUntil { io.sentBytes == Array("ls".utf8) })
        io.clearSent()
        controller.sendInterrupt()
        #expect(await waitUntil { io.sentBytes == [0x03] })
    }
}
#endif
