import SwiftUI
import TildeDesign

/// "Generate key" sheet: name, type (Ed25519 default), comment, iCloud Keychain toggle. Placeholder (WS3).
public struct GenerateKeySheet: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationStack {
            ContentUnavailableView("Generate key", systemImage: "key.fill")
                .navigationTitle("New Key")
                .toolbar { Button("Close") { dismiss() } }
        }
    }
}
