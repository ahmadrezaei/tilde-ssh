import Testing
import TildeCore
@testable import TildeSSH

@Suite struct QuickConnectParserTests {
    let parser = QuickConnectParser(defaultUsername: "me")

    private func target(_ input: String) -> ConnectionTarget? { parser.parse(input)?.target }

    @Test func plainHostUsesDefaults() {
        #expect(target("example.com") == ConnectionTarget(host: "example.com", port: 22, username: "me"))
        #expect(target("  10.0.0.5  ") == ConnectionTarget(host: "10.0.0.5", port: 22, username: "me"))
    }

    @Test func userAndPort() {
        #expect(target("deploy@host") == ConnectionTarget(host: "host", port: 22, username: "deploy"))
        #expect(target("deploy@host:2222") == ConnectionTarget(host: "host", port: 2222, username: "deploy"))
        #expect(target("host:2200") == ConnectionTarget(host: "host", port: 2200, username: "me"))
    }

    @Test func ipv6() {
        #expect(target("[::1]:22") == ConnectionTarget(host: "::1", port: 22, username: "me"))
        #expect(target("root@[2001:db8::7]:2222") == ConnectionTarget(host: "2001:db8::7", port: 2222, username: "root"))
        #expect(target("[fe80::1]") == ConnectionTarget(host: "fe80::1", port: 22, username: "me"))
        // A bare literal cannot carry a port.
        #expect(target("2001:db8::7") == ConnectionTarget(host: "2001:db8::7", port: 22, username: "me"))
    }

    @Test func sshURL() {
        #expect(target("ssh://root@example.com:2022") == ConnectionTarget(host: "example.com", port: 2022, username: "root"))
        #expect(target("ssh://example.com/") == ConnectionTarget(host: "example.com", port: 22, username: "me"))
        #expect(target("SSH://u%40corp@h") == ConnectionTarget(host: "h", port: 22, username: "u@corp"))
        #expect(target("ssh://[::1]:2200/path") == ConnectionTarget(host: "::1", port: 2200, username: "me"))
    }

    @Test func sshCommandLine() {
        let result = parser.parse("ssh deploy@10.0.1.12 -p 2222 -i ~/.ssh/macbook_ed25519 -J ops@bastion.example.com:2200")
        #expect(result?.target == ConnectionTarget(host: "10.0.1.12", port: 2222, username: "deploy"))
        #expect(result?.keyName == "macbook_ed25519")
        #expect(result?.jump == ConnectionTarget(host: "bastion.example.com", port: 2200, username: "ops"))
    }

    @Test func sshFlagsInAnyOrder() {
        #expect(parser.parse("ssh -p2222 -l root host")?.target == ConnectionTarget(host: "host", port: 2222, username: "root"))
        #expect(parser.parse("ssh -tt -A -v host")?.target == ConnectionTarget(host: "host", port: 22, username: "me"))
        #expect(parser.parse("ssh -o Port=2201 -o User=alice host")?.target == ConnectionTarget(host: "host", port: 2201, username: "alice"))
        #expect(parser.parse("ssh -i key host ls -la /tmp")?.target.host == "host")
        #expect(parser.parse("ssh -o ProxyJump=j1 host")?.jump?.host == "j1")
        #expect(parser.parse("ssh -J a,b host")?.jump?.host == "a")
    }

    @Test func userInDestinationBeatsDashL() {
        #expect(parser.parse("ssh -l other bob@host")?.target.username == "bob")
    }

    @Test func quotedIdentityPath() {
        #expect(parser.parse("ssh -i \"~/My Keys/id_ed25519\" host")?.keyName == "id_ed25519")
    }

    @Test func rejectsNonTargets() {
        #expect(parser.parse("") == nil)
        #expect(parser.parse("   ") == nil)
        #expect(parser.parse("two words") == nil)
        #expect(parser.parse("ssh") == nil)
        #expect(parser.parse("ssh -p") == nil)
        #expect(parser.parse("ssh -p abc host") == nil)
        #expect(parser.parse("host:0") == nil)
        #expect(parser.parse("host:70000") == nil)
        #expect(parser.parse("host:abc") == nil)
        #expect(parser.parse("@host") == nil)
        #expect(parser.parse("[::1") == nil)
        #expect(parser.parse("bad/host") == nil)
        #expect(parser.parse("ssh -Z host") == nil)
    }
}

@Suite struct SSHConfigParserTests {
    let parser = SSHConfigParser()

    @Test func parsesHostBlocks() {
        let hosts = parser.parse("""
        # my servers
        Host prod-api
            HostName 10.0.1.12
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
            ProxyJump bastion

        Host bastion
            HostName bastion.example.com
            User ops
        """)
        #expect(hosts == [
            SSHConfigHost(alias: "prod-api", hostName: "10.0.1.12", user: "deploy", port: 2222, identityFiles: ["~/.ssh/id_ed25519"], proxyJump: "bastion"),
            SSHConfigHost(alias: "bastion", hostName: "bastion.example.com", user: "ops"),
        ])
    }

    @Test func keysAreCaseInsensitiveAndAcceptEquals() {
        let hosts = parser.parse("""
        host a
          HOSTNAME=a.example.com
          user = alice
          PORT=2200
          identityfile "~/.ssh/with space"
        """)
        #expect(hosts == [SSHConfigHost(alias: "a", hostName: "a.example.com", user: "alice", port: 2200, identityFiles: ["~/.ssh/with space"])])
    }

    @Test func wildcardsAndNegationsAreSkipped() {
        let hosts = parser.parse("""
        Host *
            User everyone
            ServerAliveInterval 30
        Host *.internal prod-?
            User nobody
        Host real !skipme
            HostName real.example.com
        """)
        #expect(hosts.map(\.alias) == ["real"])
        #expect(hosts[0].user == nil)
    }

    @Test func oneBlockCanDeclareSeveralAliases() {
        let hosts = parser.parse("""
        Host web1 web2
            User deploy
        """)
        #expect(hosts.map(\.alias) == ["web1", "web2"])
        #expect(hosts.allSatisfy { $0.user == "deploy" })
    }

    @Test func commentsAreIgnoredIncludingTrailingOnes() {
        let hosts = parser.parse("""
        Host a   # the first
            # HostName ignored.example.com
            HostName a.example.com # real
            User "al#ice"
        """)
        #expect(hosts == [SSHConfigHost(alias: "a", hostName: "a.example.com", user: "al#ice")])
    }

    @Test func firstValueWinsAndIdentityFilesAccumulate() {
        let hosts = parser.parse("""
        Host a
            HostName first
            HostName second
            IdentityFile one
            IdentityFile two
        Host a
            User later
        """)
        #expect(hosts == [SSHConfigHost(alias: "a", hostName: "first", user: "later", identityFiles: ["one", "two"])])
    }

    @Test func matchBlocksAndUnknownKeywordsAreIgnored() {
        let hosts = parser.parse("""
        Host a
            ForwardAgent yes
            ProxyCommand nc %h %p
            User kept
        Match host b
            User ignored
        Host c
            User c-user
        """)
        #expect(hosts == [SSHConfigHost(alias: "a", user: "kept"), SSHConfigHost(alias: "c", user: "c-user")])
    }

    @Test func invalidPortAndProxyJumpNoneAreDropped() {
        let hosts = parser.parse("""
        Host a
            Port banana
            ProxyJump none
        Host b
            Port 99999
        """)
        #expect(hosts == [SSHConfigHost(alias: "a"), SSHConfigHost(alias: "b")])
    }

    @Test func settingsBeforeAnyHostAreIgnoredAndEmptyInputIsEmpty() {
        #expect(parser.parse("User global\nHostName nowhere") == [])
        #expect(parser.parse("") == [])
    }

    @Test func windowsLineEndings() {
        let hosts = parser.parse("Host a\r\n    HostName a.example.com\r\n")
        #expect(hosts == [SSHConfigHost(alias: "a", hostName: "a.example.com")])
    }
}
