import Foundation
import NIOCore
import Synchronization

/// The algorithm name-lists from the server's `SSH_MSG_KEXINIT` (RFC 4253 section 7.1).
struct ServerKexInit: Equatable, Sendable {
    var kexAlgorithms: [String]
    var hostKeyAlgorithms: [String]
    var ciphersClientToServer: [String]
    var macsClientToServer: [String]

    /// Parses the *payload* of a KEXINIT packet (starting with the message number 20).
    static func parse(payload: Data) -> ServerKexInit? {
        var reader = SSHWireReader(payload)
        guard let type = reader.readBytes(1), type.first == 20, reader.readBytes(16) != nil else { return nil }
        func nameList() -> [String]? {
            guard let raw = reader.readString() else { return nil }
            return raw.isEmpty ? [] : raw.split(separator: ",").map(String.init)
        }
        guard let kex = nameList(), let hostKeys = nameList(), let cipherC2S = nameList(), nameList() != nil,
              let macC2S = nameList() else { return nil }
        return ServerKexInit(kexAlgorithms: kex, hostKeyAlgorithms: hostKeys, ciphersClientToServer: cipherC2S, macsClientToServer: macC2S)
    }
}

/// Everything the server said in the clear before the encrypted channel came up.
struct ServerHello: Equatable, Sendable {
    /// The identification string without the line ending, e.g. `SSH-2.0-OpenSSH_9.7`.
    var banner: String?
    var kexInit: ServerKexInit?
}

/// Thread-safe holder written by `ServerHelloSniffer` (event loop) and read by the connecting task.
final class ServerHelloBox: Sendable {
    private let storage = Mutex(ServerHello())
    var value: ServerHello { storage.withLock { $0 } }
    func update(_ change: (inout ServerHello) -> Void) { storage.withLock { change(&$0) } }
}

/// A pass-through inbound handler placed in front of `NIOSSHHandler`. NIOSSH does not surface the server's
/// identification string or its KEXINIT, but both travel unencrypted, so we read them off the wire.
/// The bytes are forwarded unchanged.
final class ServerHelloSniffer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let box: ServerHelloBox
    private var pending = Data()
    private var finished = false
    /// Give up if the server sends this much without a recognisable hello (not an SSH server, or garbage).
    private static let limit = 64 * 1024

    init(box: ServerHelloBox) { self.box = box }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if !finished { consume(buffer) }
        context.fireChannelRead(data)
    }

    private func consume(_ buffer: ByteBuffer) {
        pending.append(contentsOf: buffer.readableBytesView)
        if pending.count > Self.limit { finished = true; pending = Data(); return }

        // 1. Identification string: the first line starting with "SSH-" (servers may send other lines first).
        if box.value.banner == nil {
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[(newline + 1)...])
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("SSH-") {
                    box.update { $0.banner = text }
                    break
                }
            }
            if box.value.banner == nil { return }
        }

        // 2. The first binary packet is the server's KEXINIT: uint32 length, byte padding, payload.
        guard pending.count >= 5 else { return }
        let length = pending.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 1, length < Self.limit else { finished = true; return }
        guard pending.count >= 4 + length else { return }
        let padding = Int(pending[pending.startIndex + 4])
        let payloadLength = length - 1 - padding
        if payloadLength > 0 {
            let payload = pending.subdata(in: (pending.startIndex + 5)..<(pending.startIndex + 5 + payloadLength))
            if let kexInit = ServerKexInit.parse(payload: payload) {
                box.update { $0.kexInit = kexInit }
            }
        }
        finished = true
        pending = Data()
    }
}

/// Which algorithms were negotiated, and which category failed when there is no overlap.
enum AlgorithmNegotiation {
    /// RFC 4253: the first algorithm on the client's list that the server also offers.
    static func choose(client: [String], server: [String]) -> String? {
        client.first(where: { server.contains($0) })
    }

    /// Host key algorithms NIOSSH can verify.
    static let supportedHostKeyAlgorithms = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"]

    /// Finds the first algorithm category with no common entry. Returns `(kind, serverOffer)`.
    static func firstMismatch(
        clientKex: [String], clientCiphers: [String], server: ServerKexInit
    ) -> (kind: String, offered: [String])? {
        if choose(client: clientKex, server: server.kexAlgorithms) == nil { return ("kex", server.kexAlgorithms) }
        if choose(client: supportedHostKeyAlgorithms, server: server.hostKeyAlgorithms) == nil { return ("host key", server.hostKeyAlgorithms) }
        if choose(client: clientCiphers, server: server.ciphersClientToServer) == nil { return ("cipher", server.ciphersClientToServer) }
        return nil
    }
}
