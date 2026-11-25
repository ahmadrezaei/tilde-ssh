import TildeCore
import TildeDesign

public extension EnvTone {
    /// Maps the domain `ServerEnvironment` to the design token (TildeDesign cannot depend on TildeCore).
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
