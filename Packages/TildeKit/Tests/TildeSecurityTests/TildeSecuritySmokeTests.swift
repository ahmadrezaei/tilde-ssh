import Testing
@testable import TildeSecurity

@Suite struct TildeSecuritySmokeTests {
    @Test func moduleLoads() { #expect(TildeSecurityModule.name == "TildeSecurity") }
}
