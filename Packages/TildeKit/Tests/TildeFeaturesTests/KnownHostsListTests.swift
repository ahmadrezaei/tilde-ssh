import Foundation
import SwiftData
import SwiftUI
import Synchronization
import Testing
import TildeCore
import TildeStore
@testable import TildeFeatures

@MainActor
@Suite struct KnownHostsListTests {
    @Test func algorithmBadgesAreShort() {
        #expect(KnownHostFormat.algorithmBadge("ssh-ed25519") == "ED25519")
        #expect(KnownHostFormat.algorithmBadge("ecdsa-sha2-nistp256") == "ECDSA-P256")
        #expect(KnownHostFormat.algorithmBadge("ssh-rsa") == "RSA")
        #expect(KnownHostFormat.algorithmBadge("sk-ssh-ed25519@openssh.com") == "SK-SSH-ED25519@OPENSSH.COM")
    }

    @Test func statusTitles() {
        #expect(KnownHostFormat.statusTitle(.trusted) == "Trusted")
        #expect(KnownHostFormat.statusTitle(.conflicted) == "Conflicted")
    }

    @Test func forgettingThroughTheRepositoryRemovesThePin() throws {
        let container = try ModelContainerFactory.make(.inMemory)
        let context = container.mainContext
        let host = KnownHost(endpoint: "10.0.1.12", algorithm: "ssh-ed25519", publicKeyBase64: "AAAA", fingerprintSHA256: "SHA256:abc", trustedOnDevice: "iPhone")
        context.insert(host)
        try context.save()
        try KnownHostRepository(context: context).forget(host)
        #expect(try context.fetch(FetchDescriptor<KnownHost>()).isEmpty)
    }

    @Test func sidebarToggleFlipsBetweenAllAndDetailOnly() {
        let coordinator = SessionCoordinator(services: TildeServices.preview)
        let navigator = coordinator.navigator(for: UUID())
        #expect(navigator.columnVisibility == .all)
        navigator.toggleSidebar()
        #expect(navigator.columnVisibility == .detailOnly)
        navigator.toggleSidebar()
        #expect(navigator.columnVisibility == .all)
    }
}
