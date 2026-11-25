import Foundation
import Synchronization
import Testing
import TildeCore
@testable import TildeFeatures

/// A `TerminalIO` that records what reaches the "remote".
final class RecordingIO: TerminalIO {
    let output = AsyncStream<Data> { _ in }
    private let log = Mutex<[Data]>([])
    var sent: [String] { log.withLock { $0.map { String(decoding: $0, as: UTF8.self) } } }
    func send(_ bytes: Data) { log.withLock { $0.append(bytes) } }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {}
}

/// Collects the texts the guard asked about.
final class AskedLog: Sendable {
    private let items = Mutex<[String]>([])
    func add(_ text: String) { items.withLock { $0.append(text) } }
    var all: [String] { items.withLock { $0 } }
}

private let esc = "\u{1B}"

@Suite struct PasteGuardPolicyTests {
    @Test func modes() {
        #expect(PasteGuardPolicy.requiresConfirmation(mode: .prodOnly, environment: .prod))
        #expect(!PasteGuardPolicy.requiresConfirmation(mode: .prodOnly, environment: .staging))
        #expect(PasteGuardPolicy.requiresConfirmation(mode: .always, environment: .none))
        #expect(!PasteGuardPolicy.requiresConfirmation(mode: .never, environment: .prod))
    }

    @Test func linesSkipEmptyOnes() {
        #expect(PasteGuardPolicy.lines(of: "a\r\nb\n\nc\r") == ["a", "b", "c"])
        #expect(PasteGuardPolicy.lines(of: "single") == ["single"])
        #expect(PasteGuardPolicy.lines(of: "\n\n").isEmpty)
    }

    @Test func payloadStripsBracketedPasteMarkers() {
        let data = Data("\(esc)[200~one\ntwo\(esc)[201~".utf8)
        #expect(PasteGuardPolicy.payload(of: data) == "one\ntwo")
        #expect(PasteGuardPolicy.payload(of: Data("plain".utf8)) == "plain")
    }
}

@Suite struct PasteGuardIOTests {
    private func makeGuard(_ io: RecordingIO, confirms: Bool = true, delay: Duration = .milliseconds(40),
                           shouldConfirm: Bool = true, asked: AskedLog = AskedLog()) -> PasteGuardIO {
        PasteGuardIO(base: io, shouldConfirm: { shouldConfirm }, confirm: { text in
            asked.add(text)
            try? await Task.sleep(for: delay)
            return confirms
        })
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(150)) }

    @Test func keystrokesAndEscapeSequencesPassStraightThrough() {
        let io = RecordingIO()
        let guarded = makeGuard(io)
        guarded.send(Data("a".utf8))
        guarded.send(Data("\r".utf8))
        guarded.send(Data("\(esc)[A".utf8))        // arrow up
        guarded.send(Data("\(esc)\r".utf8))        // Meta-Return
        guarded.send(Data("ls -la".utf8))          // a multi-byte chunk without a newline
        #expect(io.sent == ["a", "\r", "\(esc)[A", "\(esc)\r", "ls -la"])
    }

    @Test func aOneLinePasteWithATrailingNewlineIsGated() async {
        // `rm -rf /` plus a newline runs the moment it arrives, so it must ask even though it is a single line.
        let io = RecordingIO()
        let asked = AskedLog()
        let guarded = makeGuard(io, asked: asked)
        guarded.send(Data("rm -rf /\n".utf8))
        #expect(io.sent.isEmpty)
        await settle()
        #expect(asked.all == ["rm -rf /\n"])
        #expect(io.sent == ["rm -rf /\n"])
    }

    @Test func aRejectedOneLinePasteNeverRuns() async {
        let io = RecordingIO()
        let guarded = makeGuard(io, confirms: false)
        guarded.send(Data("rm -rf /\r".utf8))
        await settle()
        #expect(io.sent.isEmpty)
    }

    @Test func multiLinePasteIsHeldUntilApproved() async {
        let io = RecordingIO()
        let asked = AskedLog()
        let guarded = makeGuard(io, asked: asked)
        guarded.send(Data("rm -rf a\nrm -rf b\n".utf8))
        #expect(io.sent.isEmpty)
        await settle()
        #expect(io.sent == ["rm -rf a\nrm -rf b\n"])
        #expect(asked.all == ["rm -rf a\nrm -rf b\n"])
    }

    @Test func rejectedPasteNeverReachesTheServer() async {
        let io = RecordingIO()
        let guarded = makeGuard(io, confirms: false)
        guarded.send(Data("one\ntwo".utf8))
        await settle()
        #expect(io.sent.isEmpty)
    }

    @Test func keystrokesDuringAConfirmationQueueBehindIt() async {
        let io = RecordingIO()
        let guarded = makeGuard(io)
        guarded.send(Data("one\ntwo".utf8))
        guarded.send(Data("x".utf8))
        #expect(io.sent.isEmpty)
        await settle()
        #expect(io.sent == ["one\ntwo", "x"])
    }

    @Test func queuedKeystrokesStillArriveWhenThePasteIsRejected() async {
        let io = RecordingIO()
        let guarded = makeGuard(io, confirms: false)
        guarded.send(Data("one\ntwo".utf8))
        guarded.send(Data("x".utf8))
        await settle()
        #expect(io.sent == ["x"])
    }

    @Test func aPasteQueuedBehindAConfirmationIsAskedAboutToo() async {
        // Chunks that wait behind a confirmation are classified again when their turn comes: a second paste must not
        // slip through unchecked just because it arrived while the first question was open.
        let io = RecordingIO()
        let asked = AskedLog()
        let guarded = makeGuard(io, asked: asked)
        guarded.send(Data("first\nfirst2".utf8))
        guarded.send(Data("rm -rf /\n".utf8))
        guarded.send(Data("y".utf8))
        #expect(io.sent.isEmpty)
        await settle()
        await settle()
        #expect(asked.all == ["first\nfirst2", "rm -rf /\n"])
        #expect(io.sent == ["first\nfirst2", "rm -rf /\n", "y"])
    }

    @Test func aRejectedQueuedPasteIsDroppedButItsNeighboursSurvive() async {
        // Answers are per paste; here the user rejects everything: only plain keystrokes arrive, in order.
        let io = RecordingIO()
        let guarded = makeGuard(io, confirms: false)
        guarded.send(Data("one\ntwo".utf8))
        guarded.send(Data("a".utf8))
        guarded.send(Data("rm -rf /\n".utf8))
        guarded.send(Data("b".utf8))
        await settle()
        await settle()
        #expect(io.sent == ["a", "b"])
    }

    @Test func keystrokesNeverOvertakeAnApprovedPaste() async {
        let io = RecordingIO()
        let guarded = makeGuard(io, delay: .milliseconds(20))
        guarded.send(Data("one\ntwo".utf8))
        for key in ["a", "b", "c"] { guarded.send(Data(key.utf8)) }
        await settle()
        #expect(io.sent == ["one\ntwo", "a", "b", "c"])
    }

    @Test func bracketedPasteSplitAcrossSendsIsOneConfirmation() async {
        let io = RecordingIO()
        let asked = AskedLog()
        let guarded = makeGuard(io, asked: asked)
        guarded.send(Data("\(esc)[200~".utf8))
        guarded.send(Data("line1\nline2".utf8))
        #expect(io.sent.isEmpty)
        guarded.send(Data("\(esc)[201~".utf8))
        await settle()
        #expect(asked.all == ["line1\nline2"])
        #expect(io.sent == ["\(esc)[200~line1\nline2\(esc)[201~"])
    }

    @Test func bracketedPasteWithoutNewlineIsNotHeld() {
        let io = RecordingIO()
        let guarded = makeGuard(io)
        guarded.send(Data("\(esc)[200~single line\(esc)[201~".utf8))
        #expect(io.sent == ["\(esc)[200~single line\(esc)[201~"])
    }

    @Test func policyOffMeansNoQuestion() {
        let io = RecordingIO()
        let asked = AskedLog()
        let guarded = makeGuard(io, shouldConfirm: false, asked: asked)
        guarded.send(Data("a\nb".utf8))
        #expect(io.sent == ["a\nb"])
        #expect(asked.all.isEmpty)
    }
}
