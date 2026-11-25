import Foundation
import Testing
import TildeCore
@testable import TildeTerminal

@Suite struct ThemeTests {
    @Test func builtInThemesAreComplete() {
        #expect(TerminalTheme.builtIn.map(\.id) == ["tilde-night", "tilde-day", "midnight-hc"])
        for theme in TerminalTheme.builtIn { #expect(theme.ansi.count == 16) }
        #expect(TerminalTheme.theme(withID: "nope") == .tildeNight)
        #expect(TerminalTheme.tildeNight.isDark && !TerminalTheme.tildeDay.isDark)
    }

    @Test func defaultThemeMatchesDesign() {
        let t = TerminalTheme.tildeNight
        #expect(t.background == 0x0B0F14 && t.foreground == 0xD6DEE6 && t.cursor == 0x2DD4BF)
        #expect(t.ansi[1] == 0xF7525F && t.ansi[15] == 0xF5F8FA)
    }

    @Test func highContrastMeetsAAA() {
        let t = TerminalTheme.midnightHighContrast
        #expect(TerminalTheme.contrastRatio(t.foreground, t.background) >= 7)
        // Every ANSI slot except black (slot 0, used for backgrounds) reaches 7:1 on the background.
        for index in 1..<16 {
            #expect(TerminalTheme.contrastRatio(t.ansi[index], t.background) >= 7, "slot \(index)")
        }
    }

    @Test func dayThemeMeetsAA() {
        let t = TerminalTheme.tildeDay
        #expect(TerminalTheme.contrastRatio(t.foreground, t.background) >= 7)
        for index in 1..<16 {
            #expect(TerminalTheme.contrastRatio(t.ansi[index], t.background) >= 4.5, "slot \(index)")
        }
    }
}

@Suite struct KeyBarStyleTests {
    @Test func styleFollowsHardwareKeyboard() {
        #expect(KeyBarStyle.resolve(hardwareKeyboardAttached: false, mode: .hidden) == .full)
        #expect(KeyBarStyle.resolve(hardwareKeyboardAttached: false, mode: .slimStrip) == .full)
        #expect(KeyBarStyle.resolve(hardwareKeyboardAttached: true, mode: .slimStrip) == .slim)
        #expect(KeyBarStyle.resolve(hardwareKeyboardAttached: true, mode: .hidden) == .hidden)
    }
}

@Suite struct PasteGuardTests {
    @Test func confirmationDependsOnModeAndEnvironment() {
        #expect(PasteConfirmationMode.prodOnly.requiresConfirmation(for: .prod))
        #expect(!PasteConfirmationMode.prodOnly.requiresConfirmation(for: .staging))
        #expect(!PasteConfirmationMode.prodOnly.requiresConfirmation(for: .none))
        #expect(PasteConfirmationMode.always.requiresConfirmation(for: .dev))
        #expect(!PasteConfirmationMode.never.requiresConfirmation(for: .prod))
    }

    @Test func multiLineDetection() {
        #expect(PasteRequest.isMultiLine("a\nb"))
        #expect(PasteRequest.isMultiLine("ls\r"))
        #expect(PasteRequest.isMultiLine("a\r\nb"))
        #expect(!PasteRequest.isMultiLine("ls -la"))
    }

    @Test func aTrailingReturnDoesNotMakeASnippetMultiLine() {
        #expect(!PasteRequest.hasMultipleLines("df -h"))
        #expect(!PasteRequest.hasMultipleLines("df -h\r"))
        #expect(!PasteRequest.hasMultipleLines("\n\n"))
        #expect(PasteRequest.hasMultipleLines("a\nb"))
        #expect(PasteRequest.hasMultipleLines("a\r\nb\r"))
    }

    @Test func requestCountsLinesAndPreviews() {
        let text = (1...14).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let request = PasteRequest(text: text, environment: .prod)
        #expect(request.lineCount == 14)
        #expect(request.preview.count == 5)
        #expect(request.preview.first == "line 1")
        #expect(PasteRequest(text: "a\nb", environment: .none).lineCount == 2)
    }
}

@Suite struct SnippetHelpersTests {
    @Test func placeholders() {
        let command = "systemctl status <unit> --since <when> && journalctl -u <unit>"
        #expect(SnippetPlaceholders.names(in: command) == ["unit", "when"])
        #expect(SnippetPlaceholders.fill(command, values: ["unit": "nginx", "when": "today"])
                == "systemctl status nginx --since today && journalctl -u nginx")
        #expect(SnippetPlaceholders.fill(command, values: ["unit": "nginx"]).contains("<when>"))
        #expect(SnippetPlaceholders.names(in: "ls -la").isEmpty)
        #expect(SnippetPlaceholders.names(in: "echo 1 < 2 > out").isEmpty)
    }

    @Test func fuzzyMatching() {
        #expect(FuzzyMatch.score("kp", in: "kubectl pods") != nil)
        #expect(FuzzyMatch.score("zz", in: "kubectl pods") == nil)
        #expect((FuzzyMatch.score("pod", in: "pods") ?? 0) > (FuzzyMatch.score("pod", in: "p-o-d") ?? 0))
        #expect(FuzzyMatch.score("", in: "anything") == 0)
    }
}

@MainActor
@Suite struct SettingsTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "tilde.test.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func defaultsMatchDesign() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = TerminalSettings(defaults: defaults, layoutStore: UserDefaultsKeyBarLayoutStore(defaults: defaults, scope: "test"))
        #expect(settings.theme == .tildeNight)
        #expect(settings.cursorShape == .block && !settings.cursorBlink)
        #expect(settings.osc52 == .off)
        #expect(settings.pasteConfirmation == .prodOnly)
        #expect(settings.scrollbackLines == 10_000)
        #expect(settings.keyBarLayout == .devOps)
        #expect(settings.optionAsMeta && settings.commandPeriodSendsEscape && settings.hapticsEnabled)
    }

    @Test func valuesPersistAcrossInstances() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsKeyBarLayoutStore(defaults: defaults, scope: "test")
        let first = TerminalSettings(defaults: defaults, layoutStore: store)
        first.themeID = TerminalTheme.midnightHighContrast.id
        first.osc52 = .writeOnly
        first.setFontSize(200)
        first.keyBarLayout = .vim
        let second = TerminalSettings(defaults: defaults, layoutStore: store)
        #expect(second.theme == .midnightHighContrast)
        #expect(second.osc52 == .writeOnly)
        #expect(second.fontSize == TerminalAppearance.maximumFontSize)
        #expect(second.keyBarLayout == .vim)
        #expect(second.keyBarConfiguration.layout == .vim)
    }

    @Test func fontSizeIsClamped() {
        #expect(TerminalAppearance.clamp(3) == 9)
        #expect(TerminalAppearance.clamp(100) == 32)
        #expect(TerminalAppearance(fontSize: 5).fontSize == 9)
        #expect(TerminalBehavior(scrollbackLines: 999_999).scrollbackLines == 100_000)
    }

    @Test func controllerClampsAndNotifies() {
        let controller = TerminalController()
        var received: [Double] = []
        controller.fontSizeChanged = { received.append($0) }
        controller.fontSize = 12
        controller.setFontSize(2)
        #expect(controller.fontSize == 9 && received == [9])
        controller.increaseFontSize()
        #expect(controller.fontSize == 10)
        #expect(controller.fontSizeHUD == "10 pt")
    }

    @Test func modifierHUDText() {
        let state = TerminalInputState()
        #expect(state.hudText == nil)
        state.tap(.ctrl)
        #expect(state.hudText == "CTRL")
        state.tap(.alt)
        #expect(state.hudText == "CTRL+ALT")
        _ = state.consume()
        #expect(state.hudText == nil)
        state.lock(.ctrl)
        #expect(state.hudText == "CTRL 🔒")
    }
}
