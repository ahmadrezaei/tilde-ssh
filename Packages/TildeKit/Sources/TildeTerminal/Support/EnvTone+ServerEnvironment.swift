import TildeCore
import TildeDesign

// Internal on purpose: TildeFeatures declares the public equivalent. (TildeDesign cannot see TildeCore.)
extension EnvTone {
    init(_ environment: ServerEnvironment) {
        switch environment {
        case .none: self = .none
        case .dev: self = .dev
        case .staging: self = .staging
        case .prod: self = .prod
        case .lab: self = .lab
        }
    }
}
