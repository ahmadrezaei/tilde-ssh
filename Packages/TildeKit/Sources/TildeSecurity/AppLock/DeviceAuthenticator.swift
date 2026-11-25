import Foundation
import LocalAuthentication
import SwiftUI

/// The kind of biometry the device offers.
public enum BiometryKind: Sendable, Equatable {
    case none, touchID, faceID, opticID

    /// "Face ID", "Touch ID", "Optic ID", or "Passcode" when there is no biometry.
    public var displayName: String {
        switch self {
        case .none: "Passcode"
        case .touchID: "Touch ID"
        case .faceID: "Face ID"
        case .opticID: "Optic ID"
        }
    }

    /// SF Symbol for the unlock button.
    public var symbolName: String {
        switch self {
        case .none: "lock.open.fill"
        case .touchID: "touchid"
        case .faceID: "faceid"
        case .opticID: "opticid"
        }
    }
}

/// Something that can prove the device owner is present. `LocalAuthenticator` is the real one; tests and
/// previews inject fakes.
public protocol DeviceAuthenticating: Sendable {
    /// `true` when the device can authenticate its owner at all (a passcode is set, biometry enrolled...).
    var canAuthenticate: Bool { get }
    var biometry: BiometryKind { get }
    /// Shows the system prompt. Returns `true` on success; cancel and failure both return `false`.
    func authenticate(reason: String) async -> Bool
}

/// LocalAuthentication with `.deviceOwnerAuthentication`: biometrics with the device passcode as fallback.
public struct LocalAuthenticator: DeviceAuthenticating {
    public init() {}

    public var canAuthenticate: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    public var biometry: BiometryKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .none }
        switch context.biometryType {
        case .touchID: return .touchID
        case .faceID: return .faceID
        case .opticID: return .opticID
        default: return .none
        }
    }

    public func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// An authenticator that always answers the same way. For previews and tests.
public struct StubAuthenticator: DeviceAuthenticating {
    public var canAuthenticate: Bool
    public var biometry: BiometryKind
    public var succeeds: Bool

    public init(canAuthenticate: Bool = true, biometry: BiometryKind = .faceID, succeeds: Bool = true) {
        self.canAuthenticate = canAuthenticate
        self.biometry = biometry
        self.succeeds = succeeds
    }

    public func authenticate(reason: String) async -> Bool { succeeds }
}

public extension EnvironmentValues {
    /// Used by the key manager to gate "Export private key". Defaults to the real LocalAuthentication prompt.
    @Entry var tildeAuthenticator: any DeviceAuthenticating = LocalAuthenticator()
}
