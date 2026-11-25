import Testing
@testable import TildeTerminal

@Suite struct TildeTerminalSmokeTests {
    @Test func moduleLoads() { #expect(TildeTerminalModule.name == "TildeTerminal") }
}
