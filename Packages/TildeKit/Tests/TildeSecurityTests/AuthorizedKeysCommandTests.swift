import Foundation
import Testing
@testable import TildeSecurity

@Suite struct AuthorizedKeysCommandTests {
    @Test func shellQuoting() {
        #expect(AuthorizedKeysCommand.shellQuote("abc") == "'abc'")
        #expect(AuthorizedKeysCommand.shellQuote("it's") == "'it'\\''s'")
        #expect(AuthorizedKeysCommand.shellQuote("") == "''")
    }

    @Test func oneLinerMatchesTheDesign() {
        let line = "ssh-ed25519 AAAAC3 tilde@iphone"
        #expect(AuthorizedKeysCommand.oneLiner(publicKeyLine: line)
            == "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\\n' 'ssh-ed25519 AAAAC3 tilde@iphone' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys")
    }

    #if os(macOS)
    /// Runs `command` through `/bin/sh` with HOME pointing at a scratch directory and returns (stdout, status).
    private func run(_ command: String, home: URL) throws -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    private func scratchHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tilde-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func installIsIdempotentAndSafe() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let authorizedKeys = home.appendingPathComponent(".ssh/authorized_keys")
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK7v tilde's key; echo pwned $(id)"
        let command = AuthorizedKeysCommand.installCommand(publicKeyLine: line)

        // Fresh account: no ~/.ssh at all.
        var (out, status) = try run(command, home: home)
        #expect(status == 0)
        #expect(out.contains(AuthorizedKeysCommand.installedMarker))
        #expect(try String(contentsOf: authorizedKeys, encoding: .utf8) == line + "\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: authorizedKeys.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(!out.contains("pwned"))  // the comment was quoted, not executed

        // Second run: no duplicate.
        (out, status) = try run(command, home: home)
        #expect(status == 0)
        #expect(out.contains(AuthorizedKeysCommand.alreadyInstalledMarker))
        #expect(try String(contentsOf: authorizedKeys, encoding: .utf8) == line + "\n")
    }

    @Test func installRepairsMissingTrailingNewline() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        let authorizedKeys = home.appendingPathComponent(".ssh/authorized_keys")
        try "ssh-rsa AAAAB3 existing-key-without-newline".write(to: authorizedKeys, atomically: true, encoding: .utf8)

        let (out, status) = try run(AuthorizedKeysCommand.installCommand(publicKeyLine: "ssh-ed25519 AAAA new"), home: home)
        #expect(status == 0)
        #expect(out.contains(AuthorizedKeysCommand.installedMarker))
        #expect(try String(contentsOf: authorizedKeys, encoding: .utf8) == "ssh-rsa AAAAB3 existing-key-without-newline\nssh-ed25519 AAAA new\n")
    }

    @Test func oneLinerWorks() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (_, status) = try run(AuthorizedKeysCommand.oneLiner(publicKeyLine: "ssh-ed25519 AAAA a b"), home: home)
        #expect(status == 0)
        #expect(try String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8) == "ssh-ed25519 AAAA a b\n")
    }
    #endif
}
