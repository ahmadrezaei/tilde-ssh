import Foundation
import TildeCore

/// Builds the equivalent OpenSSH command line ("Copy SSH Command").
enum SSHCommand {
    static func string(for server: ServerSnapshot) -> String {
        string(target: server.target, jump: server.jump?.target)
    }

    /// The same line from a bare target, for a form that is only partly filled in.
    static func string(target: ConnectionTarget, jump: ConnectionTarget?) -> String {
        var parts = ["ssh"]
        if target.port != 22 { parts += ["-p", String(target.port)] }
        if let jump { parts += ["-J", jumpSpec(jump)] }
        parts.append("\(target.username)@\(target.host)")
        return parts.joined(separator: " ")
    }

    private static func jumpSpec(_ target: ConnectionTarget) -> String {
        let base = "\(target.username)@\(target.host)"
        return target.port == 22 ? base : "\(base):\(target.port)"
    }
}
