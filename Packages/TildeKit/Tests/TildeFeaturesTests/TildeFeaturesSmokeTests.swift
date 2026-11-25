import Testing
import TildeCore
import TildeDesign
@testable import TildeFeatures

@Suite struct TildeFeaturesSmokeTests {
    @Test func moduleLoads() { #expect(TildeFeaturesModule.name == "TildeFeatures") }

    @Test func environmentToneMapping() {
        for env in ServerEnvironment.allCases {
            #expect(EnvTone(env).rawValue == env.rawValue)
        }
    }
}
