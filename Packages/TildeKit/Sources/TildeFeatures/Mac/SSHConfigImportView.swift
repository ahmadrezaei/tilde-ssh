import SwiftUI
import TildeCore

/// Imports hosts from `~/.ssh/config` (NSOpenPanel on Mac, Files on iOS). Placeholder (WS6).
public struct SSHConfigImportView: View {
    @Environment(\.tildeServices) private var services
    private let onFinish: ([SSHConfigHost]) -> Void

    /// - Parameter onFinish: called with the hosts the user chose to import (empty on cancel).
    public init(onFinish: @escaping ([SSHConfigHost]) -> Void = { _ in }) {
        self.onFinish = onFinish
    }

    public var body: some View {
        ContentUnavailableView("Import ~/.ssh/config", systemImage: "square.and.arrow.down")
    }
}
