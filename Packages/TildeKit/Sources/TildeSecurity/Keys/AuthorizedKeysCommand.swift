import Foundation

/// The shell commands for adding a public key to a server's `authorized_keys`.
public enum AuthorizedKeysCommand {
    /// Wraps `value` in single quotes, escaping embedded quotes, so it is one literal shell word.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One line for the user to paste into a shell (`ssh-copy-id` style).
    public static func oneLiner(publicKeyLine: String) -> String {
        let line = shellQuote(publicKeyLine)
        return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo \(line) >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    /// Printed by `installCommand` when it appended the key.
    public static let installedMarker = "tilde:installed"
    /// Printed by `installCommand` when the key was already present.
    public static let alreadyInstalledMarker = "tilde:already-installed"

    /// The command Tilde runs over an exec channel (`SessionEngine.runCommand`). It is idempotent (`grep -qxF`),
    /// repairs a missing trailing newline, fixes permissions, and works whatever the account's login shell is
    /// because the script is handed to `sh -c`.
    public static func installCommand(publicKeyLine: String) -> String {
        let line = shellQuote(publicKeyLine)
        let script = """
        umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys || exit 1; \
        if grep -qxF \(line) ~/.ssh/authorized_keys; then echo \(alreadyInstalledMarker); \
        else if [ -n "$(tail -c1 ~/.ssh/authorized_keys)" ]; then echo >> ~/.ssh/authorized_keys; fi; \
        printf '%s\\n' \(line) >> ~/.ssh/authorized_keys && echo \(installedMarker); fi
        """
        return "sh -c " + shellQuote(script)
    }
}
