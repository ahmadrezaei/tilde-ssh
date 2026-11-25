import SwiftUI

/// A single-line monospaced text field for hostnames, usernames and ports: no autocorrect, no auto-capitalisation.
public struct MonoField: View {
    private let title: String
    @Binding private var text: String

    public init(_ title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    public var body: some View {
        TextField(title, text: $text)
            .tildeMono(15, relativeTo: .body)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }
}

#Preview("MonoField") {
    @Previewable @State var text = "deploy@10.0.1.12"
    MonoField("Host", text: $text).padding().background(TildeColor.bg)
}
