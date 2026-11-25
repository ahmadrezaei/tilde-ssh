import Foundation
import TildeCore

/// Backoff for automatic reconnects (design section 4.5): 1, 2, 4, 8, 15, then 30 s for every later attempt.
public struct ReconnectPolicy: Sendable, Equatable {
    /// `false` turns automatic reconnect off (Settings > Connections > Auto-reconnect).
    public var isEnabled: Bool
    /// Attempts after a drop before giving up with the last error.
    public var maxAttempts: Int
    /// Wait before attempt 1, 2, ... The last entry repeats.
    public var schedule: [Duration]

    public init(
        isEnabled: Bool = true,
        maxAttempts: Int = 10,
        schedule: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30)]
    ) {
        self.isEnabled = isEnabled
        self.maxAttempts = maxAttempts
        self.schedule = schedule.isEmpty ? [.seconds(1)] : schedule
    }

    public static let `default` = ReconnectPolicy()
    public static let disabled = ReconnectPolicy(isEnabled: false)

    /// The wait before attempt number `attempt` (1-based).
    public func delay(forAttempt attempt: Int) -> Duration {
        schedule[min(max(attempt, 1), schedule.count) - 1]
    }
}

/// Builds the lines typed into the remote shell right after it opens: tmux attach and/or a startup command.
///
/// Typing into the shell (instead of using an `exec` request) keeps the user's login environment, so `tmux`
/// is found on the usual PATH, and a missing tmux just leaves a normal shell with an error message above it.
enum StartupScript {
    /// Lines to send, each without a trailing newline.
    static func lines(for server: ServerSnapshot) -> [String] {
        let command = server.startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasCommand = !(command ?? "").isEmpty

        guard server.autoTmux else {
            return hasCommand ? [command!] : []
        }

        let name = shellQuote(sanitizedSessionName(server.tmuxSessionName))
        guard hasCommand else {
            return ["exec tmux new -A -s \(name)"]
        }
        // Run the startup command only when the session is created, never when re-attaching to it.
        let create = "exec tmux new -s \(name) \\; send-keys \(shellQuote(command!)) Enter"
        return ["tmux has-session -t \(name) 2>/dev/null && exec tmux attach -t \(name) || \(create)"]
    }

    /// tmux treats `.` and `:` specially in targets; keep names to a safe alphabet.
    static func sanitizedSessionName(_ raw: String) -> String {
        let cleaned = String(raw.map { char in
            (char.isLetter || char.isNumber || char == "-" || char == "_") ? char : "-"
        })
        return cleaned.isEmpty ? "tilde" : cleaned
    }

    /// POSIX single-quote escaping.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
