import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeStore

/// Settings > Terminal: scrollback, paste confirmation, default TERM and keep-alive.
struct TerminalSettingsSection: View {
    @AppStorage(TildeSettings.scrollbackKey) private var scrollback = TildeSettings.defaultScrollback
    @AppStorage(TildeSettings.confirmPasteKey) private var confirmPaste = PasteConfirmMode.prodOnly.rawValue
    @AppStorage(TildeSettings.defaultTermKey) private var term = TildeSettings.defaultTerm
    @AppStorage(TildeSettings.defaultKeepAliveKey) private var keepAlive = TildeSettings.defaultKeepAlive

    var body: some View {
        Stepper(value: $scrollback, in: 1_000...100_000, step: 1_000) {
            LabeledContent("Scrollback lines") { Text(scrollback.formatted()).tildeMono(13).foregroundStyle(TildeColor.text2) }
        }
        Picker("Confirm multi-line paste", selection: $confirmPaste) {
            ForEach(PasteConfirmMode.allCases) { Text($0.title).tag($0.rawValue) }
        }
        LabeledContent("Default TERM") {
            MonoField("xterm-256color", text: $term).multilineTextAlignment(.trailing)
        }
        Stepper(value: $keepAlive, in: 0...300, step: 5) {
            LabeledContent("Keep-alive") { Text(keepAlive == 0 ? "off" : "\(keepAlive) s").tildeMono(13).foregroundStyle(TildeColor.text2) }
        }
    }
}

/// Settings > Connections: default user and key, timeout, auto-reconnect, reachability probing.
struct ConnectionSettingsSection: View {
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    @AppStorage(TildeSettings.defaultUserKey) private var defaultUser = ""
    @AppStorage(TildeSettings.defaultKeyKey) private var defaultKey = ""
    @AppStorage(TildeSettings.connectTimeoutKey) private var timeout = TildeSettings.defaultConnectTimeout
    @AppStorage(TildeSettings.autoReconnectKey) private var autoReconnect = true
    @AppStorage(TildeSettings.probeReachabilityKey) private var probe = true
    @AppStorage(TildeSettings.probeOnCellularKey) private var probeOnCellular = false

    var body: some View {
        LabeledContent("Default username") {
            MonoField(TildeSettings.defaultUser, text: $defaultUser).multilineTextAlignment(.trailing)
        }
        Picker("Default key", selection: $defaultKey) {
            Text("None").tag("")
            ForEach(keys) { Text($0.name).tag($0.id.uuidString) }
        }
        Stepper(value: $timeout, in: 5...120, step: 5) {
            LabeledContent("Connect timeout") { Text("\(timeout) s").tildeMono(13).foregroundStyle(TildeColor.text2) }
        }
        Toggle("Auto-reconnect", isOn: $autoReconnect)
        Toggle("Probe reachability", isOn: $probe)
        if probe {
            Toggle("Probe on cellular", isOn: $probeOnCellular)
        }
    }
}

/// Settings > Sync. Shows what is stored; the live iCloud account status and last-sync time arrive with WS1's account
/// observer.
struct SyncSettingsSection: View {
    @Query private var servers: [Server]
    @Query private var keys: [SSHKeyRecord]
    @Query private var snippets: [Snippet]

    var body: some View {
        Section {
            LabeledContent("Servers") { Text("\(servers.count)").tildeMono(13).foregroundStyle(TildeColor.text2) }
            LabeledContent("Keys") { Text("\(keys.count)").tildeMono(13).foregroundStyle(TildeColor.text2) }
            LabeledContent("Snippets") { Text("\(snippets.count)").tildeMono(13).foregroundStyle(TildeColor.text2) }
        } header: {
            Text("Sync").tildeSectionHeader()
        } footer: {
            Text("Servers, groups, tags and snippets sync through your private iCloud database. Passwords and keys stay in iCloud Keychain.")
        }
    }
}

/// Settings > Data: import from an ssh config.
struct DataSettingsSection: View {
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @State private var showsImport = false

    var body: some View {
        Section {
            Button(Platform.isMac ? "Import ~/.ssh/config…" : "Import ssh config from Files…") { showsImport = true }
        } header: {
            Text("Data").tildeSectionHeader()
        }
        .sheet(isPresented: $showsImport) {
            SSHConfigImportView { hosts in
                showsImport = false
                guard !hosts.isEmpty else { return }
                ServerActions(context: context, secrets: services.secretStore).importHosts(hosts)
            }
        }
    }
}

/// Settings > About.
struct AboutSettingsSection: View {
    var body: some View {
        Section {
            LabeledContent("Version") { Text(Self.version).tildeMono(13).foregroundStyle(TildeColor.text2) }
            NavigationLink("Acknowledgements") { AcknowledgementsView() }
            LabeledContent("Privacy") { Text("Tilde collects nothing.").foregroundStyle(TildeColor.text2) }
        } header: {
            Text("About").tildeSectionHeader()
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// Third-party licences (the bundled `NOTICE` is generated by WS6; this is the in-app list).
struct AcknowledgementsView: View {
    private let entries: [(name: String, license: String)] = [
        ("Citadel", "MIT"), ("swift-nio-ssh (fork)", "Apache-2.0"), ("swift-nio", "Apache-2.0"),
        ("swift-crypto", "Apache-2.0"), ("swift-log", "Apache-2.0"), ("swift-collections", "Apache-2.0"),
        ("BigInt", "MIT"), ("ColorizeSwift", "MIT"), ("SwiftTerm", "MIT"), ("JetBrains Mono", "OFL-1.1"),
    ]

    var body: some View {
        List(entries, id: \.name) { entry in
            LabeledContent(entry.name) { Text(entry.license).tildeMono(12).foregroundStyle(TildeColor.text2) }
        }
        .tildeList()
        .navigationTitle("Acknowledgements")
    }
}
