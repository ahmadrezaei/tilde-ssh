import Foundation
import NIOCore
import NIOPosix
import Testing
import TildeCore
@testable import TildeSSH

/// Engine behaviour that needs a socket but not a real sshd: runs everywhere, no Docker.
@Suite @MainActor
struct LocalSocketTests {
    private func listener(onAccept: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil) async throws -> (Channel, Int) {
        var bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        if let onAccept { bootstrap = bootstrap.childChannelInitializer(onAccept) }
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return (channel, try #require(channel.localAddress?.port))
    }

    private func test(port: Int, timeout: Duration) async -> Result<ConnectionInfo, SessionError> {
        let server = ServerSnapshot(name: "local", target: ConnectionTarget(host: "127.0.0.1", port: port, username: "u"), auth: .password, passwordSecretID: UUID(), keepAliveSeconds: 0)
        return await CitadelSessionEngine().test(
            SessionRequest(server: server, connectTimeout: timeout), credentials: FakeCredentialResolver(),
            knownHosts: InMemoryKnownHostsStore(), hostKeyPrompter: AlwaysTrustPrompter(), passwordPrompter: FakePasswordPrompter()
        )
    }

    @Test func serverThatNeverSpeaksTimesOut() async throws {
        let (server, port) = try await listener()
        defer { server.close(promise: nil) }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await test(port: port, timeout: .seconds(1))
        #expect(result == .failure(.timeout(seconds: 1)))
        #expect(clock.now - start < .seconds(4))
    }

    @Test func serverThatHangsUpIsAConnectionLoss() async throws {
        let (server, port) = try await listener { channel in channel.close() }
        defer { server.close(promise: nil) }
        let result = await test(port: port, timeout: .seconds(3))
        #expect(result == .failure(.networkLost))
    }

    @Test func nothingListeningIsRefused() async throws {
        let (server, port) = try await listener()
        try await server.close()
        #expect(await test(port: port, timeout: .seconds(3)) == .failure(.refused))
    }

    @Test func reachabilityProbeMeasuresATCPConnect() async throws {
        let (server, port) = try await listener()
        defer { server.close(promise: nil) }
        let probe = NWReachabilityProbe()
        guard case .reachable(let latency) = await probe.probe(ConnectionTarget(host: "127.0.0.1", port: port, username: "u"), timeout: .seconds(2)) else {
            Issue.record("expected reachable"); return
        }
        #expect(latency < .seconds(1))

        try await server.close()
        guard case .unreachable(let reason) = await probe.probe(ConnectionTarget(host: "127.0.0.1", port: port, username: "u"), timeout: .seconds(2)) else {
            Issue.record("expected unreachable"); return
        }
        #expect(reason == "Connection refused")
        #expect(await probe.probe(ConnectionTarget(host: "", port: 22, username: "u"), timeout: .seconds(1)) == .unreachable(reason: "Invalid address"))
    }
}
