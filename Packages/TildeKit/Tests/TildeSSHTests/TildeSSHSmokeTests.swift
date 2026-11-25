import Testing
@testable import TildeSSH

@Suite struct TildeSSHSmokeTests {
    @Test func moduleLoads() { #expect(TildeSSHModule.name == "TildeSSH") }
}
