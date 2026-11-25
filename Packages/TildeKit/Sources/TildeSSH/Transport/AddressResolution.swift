import Foundation
import NIOCore

extension SSHConnector {
    /// Blocking `getaddrinfo` for TCP stream addresses, in the system's preferred order.
    static func getAddresses(host: String, port: Int) throws -> [SocketAddress] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var results: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &results) == 0, let first = results else {
            throw DNSResolutionError(host: host)
        }
        defer { freeaddrinfo(first) }

        var addresses: [SocketAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let sockaddr = entry.pointee.ai_addr {
                switch entry.pointee.ai_family {
                case AF_INET:
                    sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addresses.append(SocketAddress($0.pointee, host: host)) }
                case AF_INET6:
                    sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addresses.append(SocketAddress($0.pointee, host: host)) }
                default:
                    break
                }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }
}
