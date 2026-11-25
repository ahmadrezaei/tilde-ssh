import SwiftData
import SwiftUI
import TildeStore

/// Picker used by the server editor's Authentication section. Placeholder (WS3).
public struct KeyPicker: View {
    @Binding private var selection: SSHKeyRecord?
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]

    public init(selection: Binding<SSHKeyRecord?>) {
        self._selection = selection
    }

    public var body: some View {
        Picker("Key", selection: $selection) {
            Text("None").tag(SSHKeyRecord?.none)
            ForEach(keys) { key in
                Text(key.name).tag(Optional(key))
            }
        }
    }
}
