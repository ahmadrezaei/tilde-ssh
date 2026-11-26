import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeSecurity
import TildeStore

/// "Install on server…" (docs/DESIGN.md section 4.3): pick a server you can already reach and Tilde appends the public
/// key to its `authorized_keys` over an SSH exec channel, idempotently.
struct InstallKeySheet: View {
    let key: SSHKeyRecord

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.tildeServices) private var services
    @Query(sort: \Server.name) private var servers: [Server]

    @State private var selectedID: UUID?
    @State private var password = ""
    @State private var switchServerToKey = false
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle, running
        case installed(already: Bool)
        case failed(String)
    }

    private var selected: Server? { servers.first { $0.id == selectedID } }

    var body: some View {
        TildeSheet("Install on Server", subtitle: key.name, subtitleIsMono: true, idealHeight: 640) {
            VStack(alignment: .leading, spacing: TildeSpacing.l) {
                TildeFormSection(footer: "Adds this public key to ~/.ssh/authorized_keys on the server. Nothing is added twice.") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(key.name).tildeMono(13, weight: .semibold).foregroundStyle(TildeColor.text)
                            Spacer()
                            TypeBadge(text: key.typeBadge, tinted: true)
                        }
                        Text(key.shortFingerprint)
                            .tildeMono(11)
                            .foregroundStyle(TildeColor.text2)
                    }
                    .padding(.vertical, 8)
                }

                TildeFormSection("Server", footer: "Choose a server you can already sign in to, for example with a password.") {
                    if servers.isEmpty {
                        Text("No servers yet.").foregroundStyle(TildeColor.text3)
                    }
                    ForEach(servers) { server in
                        Button {
                            selectedID = server.id
                            phase = .idle
                        } label: {
                            ServerChoiceRow(server: server, isSelected: server.id == selectedID)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(server.id == selectedID ? .isSelected : [])
                    }
                }

                if let selected, AuthMethod(rawValue: selected.authMethodRaw) != .key || selected.key == nil {
                    TildeFormSection(footer: "Used once for this install if the server asks for a password and none is saved. It is not stored.") {
                        TildeTextRow("Password", prompt: "optional", text: $password, isMono: false, isSecure: true, contentType: .password)
                    }
                }

                if let selected {
                    TildeFormSection {
                        TildeToggleRow("Use this key for \(selected.name) afterwards", isOn: $switchServerToKey)
                    }
                }

                statusSection
            }
        } leading: {
            if phase == .running { ProgressView().controlSize(.small).accessibilityLabel("Installing") }
        } actions: {
            TildeCancelButton(isFinished ? "Done" : "Cancel") { dismiss() }
            // Installing writes to a remote authorized_keys: click only, never Return.
            TildeDefaultButton("Install", requiresClick: true) { Task { await install() } }
                .disabled(selected == nil || isFinished || phase == .running)
        }
        .presentationDetents([.large])
        .onDisappear { password = "" }
    }

    private var isFinished: Bool {
        if case .installed = phase { return true }
        return false
    }

    @ViewBuilder private var statusSection: some View {
        switch phase {
        case .idle, .running:
            EmptyView()
        case .installed(let already):
            TildeNotice(already ? "This key was already installed." : "Key installed. You can sign in with it now.", tone: .success)
        case .failed(let message):
            TildeNotice(message, tone: .danger)
        }
    }

    /// Makes `key` the server's sign-in and removes the saved password it no longer uses (the `pw:` Keychain item
    /// would otherwise stay behind with nothing referencing it).
    static func switchToKey(_ server: Server, key: SSHKeyRecord, secrets: any SecretStore) {
        let oldPassword = server.passwordSecretID
        server.key = key
        server.authMethodRaw = AuthMethod.key.rawValue
        server.passwordSecretID = nil
        server.updatedAt = .now
        if let oldPassword { try? secrets.delete(SecretRef(kind: .password, id: oldPassword)) }
    }

    private func install() async {
        guard let server = selected else { return }
        phase = .running
        let request = SessionRequest(server: ServerSnapshot(keyFlowModel: server), pty: PTYConfig(), connectTimeout: .seconds(15))
        let resolver = InstallCredentialResolver(base: services.credentials, passwordOverride: password.isEmpty ? nil : password, target: request.server.target)
        do {
            let (stdout, status) = try await services.sessionEngine.runCommand(
                AuthorizedKeysCommand.installCommand(publicKeyLine: key.publicKeyOpenSSH),
                on: request, credentials: resolver, knownHosts: services.knownHosts)
            let output = String(decoding: stdout, as: UTF8.self)
            guard status == 0 else {
                phase = .failed("The server answered with exit status \(status). The key was not installed.")
                return
            }
            phase = .installed(already: output.contains(AuthorizedKeysCommand.alreadyInstalledMarker))
            if switchServerToKey {
                Self.switchToKey(server, key: key, secrets: services.secretStore)
                try? context.save()
            }
        } catch let error as SessionError {
            phase = .failed(error.installMessage(serverName: server.name))
        } catch {
            phase = .failed("The key could not be installed.")
        }
        password = ""
    }
}

private struct ServerChoiceRow: View {
    let server: Server
    let isSelected: Bool

    var body: some View {
        HStack(spacing: TildeSpacing.m) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? TildeColor.accent : TildeColor.text3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name.isEmpty ? server.host : server.name)
                    .font(TildeFont.mono(14, weight: .semibold))
                    .foregroundStyle(TildeColor.text)
                Text("\(server.username)@\(server.host)\(server.port == 22 ? "" : ":\(server.port)")")
                    .font(TildeFont.rowSubtitle)
                    .foregroundStyle(TildeColor.text2)
            }
            Spacer()
            EnvBadge(EnvTone(rawValue: server.environmentRaw) ?? .none)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Supplies a password typed into the install sheet where the stored credentials cannot (ask-every-time servers, or a
/// password that has not arrived from iCloud Keychain yet). It answers only for `target`, the server the key is being
/// installed on: a jump host on the way gets the real resolver's answer or none, never the typed password.
struct InstallCredentialResolver: CredentialResolver {
    let base: any CredentialResolver
    let passwordOverride: String?
    let target: ConnectionTarget

    func resolve(auth: AuthMethod, keyID: UUID?, passwordSecretID: UUID?, target hop: ConnectionTarget) async throws -> ResolvedCredential {
        do {
            return try await base.resolve(auth: auth, keyID: keyID, passwordSecretID: passwordSecretID, target: hop)
        } catch SessionError.secretUnavailable(let ref) where ref.kind == .password {
            if let passwordOverride, Self.isSame(hop, target) { return .password(passwordOverride) }
            throw SessionError.secretUnavailable(ref)
        }
    }

    private static func isSame(_ a: ConnectionTarget, _ b: ConnectionTarget) -> Bool {
        a.host.caseInsensitiveCompare(b.host) == .orderedSame && a.port == b.port && a.username == b.username
    }
}

private extension SessionError {
    /// User-facing text for the install flow. Names the cause and the fix (docs/DESIGN.md section 2.5).
    func installMessage(serverName: String) -> String {
        switch self {
        case .authFailed:
            "\(serverName) did not accept the sign-in. Check the password, or pick a server you can already reach."
        case .secretUnavailable:
            "No password is available for \(serverName). Type it above."
        case .refused:
            "\(serverName) refused the connection. Is sshd running?"
        case .timeout:
            "\(serverName) did not answer in time."
        case .dnsFailure(let host):
            "The host name \(host) could not be found."
        case .networkLost:
            "The network connection was lost."
        case .hostKeyMismatch, .hostKeyRejected:
            "The host key of \(serverName) is not trusted. Connect to it once from the server list first."
        case .noCommonAlgorithm:
            "\(serverName) and Tilde share no key exchange or cipher."
        case .channelFailed(let reason), .underlying(let reason):
            reason
        }
    }
}

#Preview("InstallKeySheet") {
    InstallKeyPreviewHost()
        .modelContainer(ModelContainerFactory.preview())
        .preferredColorScheme(.dark)
}

private struct InstallKeyPreviewHost: View {
    @Query private var keys: [SSHKeyRecord]

    var body: some View {
        if let key = keys.first { InstallKeySheet(key: key) } else { Text("No preview key") }
    }
}
