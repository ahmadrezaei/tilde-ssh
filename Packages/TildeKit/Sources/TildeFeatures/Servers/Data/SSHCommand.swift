import Foundation
import TildeCore

/// Builds the equivalent OpenSSH command line ("Copy SSH Command").
enum SSHCommand {
    static func string(for server: ServerSnapshot) -> String {
        var parts = ["ssh"]
        if server.target.port != 22 { parts += ["-p", String(server.target.port)] }
        if let jump = server.jump { parts += ["-J", jumpSpec(jump.target)] }
        parts.append("\(server.target.username)@\(server.target.host)")
        return parts.joined(separator: " ")
    }

    private static func jumpSpec(_ target: ConnectionTarget) -> String {
        let base = "\(target.username)@\(target.host)"
        return target.port == 22 ? base : "\(base):\(target.port)"
    }
}
