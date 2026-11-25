import SwiftUI
import TildeCore
import TildeDesign

/// Display helpers for host key algorithm names.
enum HostKeyFormat {
    /// `ssh-ed25519` -> `ED25519`, `ecdsa-sha2-nistp256` -> `ECDSA-P256`, `ssh-rsa` -> `RSA`.
    static func label(_ algorithm: String) -> String {
        if algorithm.hasPrefix("ecdsa-sha2-nistp") { return "ECDSA-P" + algorithm.dropFirst("ecdsa-sha2-nistp".count) }
        if algorithm.contains("rsa") { return "RSA" }
        if algorithm.hasPrefix("ssh-") { return algorithm.dropFirst(4).uppercased() }
        return algorithm.uppercased()
    }

    /// The public key file on the server to compare against.
    static func serverKeyFile(_ algorithm: String) -> String {
        if algorithm.contains("ed25519") { return "ssh_host_ed25519_key.pub" }
        if algorithm.hasPrefix("ecdsa") { return "ssh_host_ecdsa_key.pub" }
        if algorithm.contains("rsa") { return "ssh_host_rsa_key.pub" }
        return "ssh_host_*_key.pub"
    }

    static func endpointLabel(_ endpoint: HostEndpoint) -> String { "\(endpoint.host):\(endpoint.port)" }

    static func trustedCaption(_ pin: PinnedHostKey) -> String {
        let date = pin.firstSeenAt.formatted(.iso8601.year().month().day())
        let device = pin.trustedOnDevice.isEmpty ? "" : " on \(pin.trustedOnDevice)"
        return "first trusted \(date)\(device)"
    }
}

// MARK: - First connection (TOFU)

/// "First connection to db-primary": the unknown-host sheet. Never auto-dismisses; the handshake is held open
/// until the user answers (up to 120 s).
struct UnknownHostSheet: View {
    let request: HostKeyRequest
    let onDecision: (HostKeyDecision) -> Void

    var body: some View {
        let challenge = request.challenge
        let key = challenge.presented
        ScrollView {
            VStack(alignment: .leading, spacing: TildeSpacing.l) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("First connection to \(challenge.serverName ?? challenge.endpoint.host)")
                        .tildeText(20, weight: .bold, relativeTo: .title3)
                        .foregroundStyle(TildeColor.text)
                    Text("\(HostKeyFormat.endpointLabel(challenge.endpoint)) presented an \(HostKeyFormat.label(key.algorithm)) key:")
                        .tildeMono(12, relativeTo: .caption)
                        .foregroundStyle(TildeColor.text2)
                }

                FingerprintBlock {
                    FingerprintRow(label: "Fingerprint", algorithm: HostKeyFormat.label(key.algorithm),
                                   fingerprint: key.fingerprintSHA256, tint: TildeColor.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Compare with").tildeSectionHeader()
                    Text("ssh-keygen -lf /etc/ssh/\(HostKeyFormat.serverKeyFile(key.algorithm))")
                        .tildeMono(12, relativeTo: .caption)
                        .foregroundStyle(TildeColor.text2)
                        .textSelection(.enabled)
                }

                VStack(spacing: TildeSpacing.s) {
                    Button("Trust & Connect") { onDecision(.trustAndSave) }.buttonStyle(.tildePrimary)
                    Button("Connect Once") { onDecision(.connectOnce) }.buttonStyle(.tildeSecondary)
                    Button("Cancel", role: .cancel) { onDecision(.reject) }
                        .buttonStyle(.plain).foregroundStyle(TildeColor.text2)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                Text("Trusting saves the key and syncs it to your other devices.")
                    .tildeText(12, relativeTo: .caption).foregroundStyle(TildeColor.text3)
            }
            .padding(TildeSpacing.l)
        }
        .background(TildeColor.bg)
        .interactiveDismissDisabled()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Changed key takeover

/// The scariest screen in the app (design section 4.6): a full-window danger takeover that cannot be swiped
/// away. The connection was aborted at key exchange, before any credentials were sent. The safe choice
/// ("Disconnect") is the big primary button; trusting the new key needs a 1.5 s press-and-hold.
struct ChangedHostKeyTakeover: View {
    let request: HostKeyRequest
    let onDecision: (HostKeyDecision) -> Void
    @State private var showsHowToVerify = false

    var body: some View {
        let challenge = request.challenge
        let presented = challenge.presented
        let isConflict = { if case .conflicted = challenge.lookup { true } else { false } }()

        ZStack {
            TildeColor.bg.ignoresSafeArea()
            RadialGradient(colors: [TildeColor.danger.opacity(0.28), .clear], center: .top, startRadius: 0, endRadius: 420)
                .ignoresSafeArea()
            TildeColor.danger.opacity(0.06).ignoresSafeArea()

            ScrollView {
                VStack(spacing: TildeSpacing.l) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(TildeColor.danger)
                        .frame(width: 64, height: 64)
                        .background(TildeColor.danger.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(TildeColor.danger.opacity(0.5), lineWidth: 1))
                        .shadow(color: TildeColor.danger.opacity(0.35), radius: 20)
                        .padding(.top, TildeSpacing.xl)
                        .accessibilityHidden(true)

                    Text(isConflict ? "HOST KEYS DISAGREE" : "HOST KEY HAS CHANGED")
                        .tildeText(20, weight: .heavy, relativeTo: .title3)
                        .tracking(0.8)
                        .foregroundStyle(TildeColor.danger)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text("\(Text(challenge.serverName ?? challenge.endpoint.host).fontWeight(.bold).foregroundStyle(TildeColor.text))  \(Text("(\(HostKeyFormat.endpointLabel(challenge.endpoint)))").foregroundStyle(TildeColor.text2))")
                        .tildeMono(14, relativeTo: .body)
                        .multilineTextAlignment(.center)

                    explanation(isConflict: isConflict)

                    FingerprintBlock(tint: TildeColor.danger.opacity(0.4)) {
                        ForEach(Array(request.pinnedKeys.enumerated()), id: \.offset) { index, pin in
                            if index > 0 { Divider().overlay(TildeColor.danger.opacity(0.2)) }
                            FingerprintRow(label: isConflict ? "Pinned" : "Expected", algorithm: HostKeyFormat.label(pin.key.algorithm),
                                           fingerprint: pin.key.fingerprintSHA256, caption: HostKeyFormat.trustedCaption(pin), tint: TildeColor.ok)
                        }
                        if !request.pinnedKeys.isEmpty { Divider().overlay(TildeColor.danger.opacity(0.2)) }
                        FingerprintRow(label: "Received", algorithm: HostKeyFormat.label(presented.algorithm),
                                       fingerprint: presented.fingerprintSHA256, tint: TildeColor.danger)
                    }

                    HStack(spacing: TildeSpacing.l) {
                        Button("Copy both fingerprints") { copyFingerprints() }
                        Button("How to verify") { showsHowToVerify = true }
                    }
                    .buttonStyle(.plain)
                    .tildeText(12, weight: .semibold, relativeTo: .caption)
                    .foregroundStyle(TildeColor.text2)
                    .padding(.bottom, 140)   // room for the pinned buttons
                }
                .padding(.horizontal, TildeSpacing.l)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: TildeSpacing.s) {
                Button("Disconnect") { onDecision(.reject) }.buttonStyle(.tildeInverted)
                HoldToConfirmButton("Hold to trust new key") { onDecision(.trustAndSave) }
            }
            .padding(.horizontal, TildeSpacing.l)
            .padding(.vertical, TildeSpacing.m)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
        .sheet(isPresented: $showsHowToVerify) { HowToVerifySheet(algorithm: presented.algorithm) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .interactiveDismissDisabled()
    }

    @ViewBuilder
    private func explanation(isConflict: Bool) -> some View {
        VStack(spacing: 8) {
            if isConflict {
                Text("Two of your devices trusted **different keys** for this server. Someone could be intercepting a connection, or the server's keys were rotated and only one device noticed.")
            } else {
                Text("Someone could be intercepting this connection (man-in-the-middle), or the server was reinstalled or its keys were rotated.")
            }
            Text("**No credentials were sent.**")
        }
        .tildeText(14, relativeTo: .subheadline)
        .foregroundStyle(TildeColor.text2)
        .multilineTextAlignment(.center)
    }

    private func copyFingerprints() {
        let pinned = request.pinnedKeys.map { "Expected \(HostKeyFormat.label($0.key.algorithm)) \($0.key.fingerprintSHA256)" }
        let received = "Received \(HostKeyFormat.label(request.challenge.presented.algorithm)) \(request.challenge.presented.fingerprintSHA256)"
        Platform.copy((pinned + [received]).joined(separator: "\n"))
    }
}

private struct HowToVerifySheet: View {
    let algorithm: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TildeSpacing.l) {
                    Text("Check the key through a channel you already trust: the provider console, a colleague, or a terminal on the server itself.")
                        .tildeText(15, relativeTo: .body)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("On the server").tildeSectionHeader()
                        Text("ssh-keygen -lf /etc/ssh/\(HostKeyFormat.serverKeyFile(algorithm))")
                            .tildeMono(12, relativeTo: .caption).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(TildeColor.surface2, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("If the printed fingerprint equals **Received**, the server was reinstalled or its keys rotated: trust the new key. If you cannot verify it, disconnect.")
                        .tildeText(15, relativeTo: .body)
                }
                .foregroundStyle(TildeColor.text)
                .padding(TildeSpacing.l)
            }
            .background(TildeColor.bg)
            .navigationTitle("How to verify")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

#Preview("Changed key takeover") {
    let mismatch = HostKeyChallenge(
        endpoint: HostEndpoint(host: "10.0.1.12"), serverName: "prod-api-01",
        presented: HostKey(algorithm: "ssh-ed25519", blobBase64: "AAAA", fingerprintSHA256: "SHA256:Zk81Lr0aP2xxxxxxxxxxxxxxxxxxxxxxxxxxxxxmQ9"),
        lookup: .mismatch(pinned: [PinnedHostKey(
            key: HostKey(algorithm: "ssh-ed25519", blobBase64: "BBBB", fingerprintSHA256: "SHA256:4f+HqTn1dQrZ0vAbCdEfGhIjKlMnOpQrStUvWx0Vw0"),
            firstSeenAt: Date(timeIntervalSince1970: 1_773_446_400), trustedOnDevice: "MacBook-Pro")])
    )
    return TakeoverPreviewHost(challenge: mismatch)
}

#Preview("Unknown host sheet") {
    let challenge = HostKeyChallenge(
        endpoint: HostEndpoint(host: "10.0.2.5"), serverName: "db-primary",
        presented: HostKey(algorithm: "ssh-ed25519", blobBase64: "AAAA", fingerprintSHA256: "SHA256:p3Kc9yFQ2nL0e1x7XvR8bq0M4aZ+u5Jd2YH6sTgVwE0"),
        lookup: .unknown
    )
    return TakeoverPreviewHost(challenge: challenge)
}

/// Previews build a request with a continuation that is never awaited.
private struct TakeoverPreviewHost: View {
    let challenge: HostKeyChallenge
    @State private var request: HostKeyRequest?

    var body: some View {
        Group {
            if let request {
                if request.isChangedKey { ChangedHostKeyTakeover(request: request) { _ in } } else { UnknownHostSheet(request: request) { _ in } }
            } else {
                Color.clear
            }
        }
        .task {
            _ = await withCheckedContinuation { (continuation: CheckedContinuation<HostKeyDecision, Never>) in
                request = HostKeyRequest(challenge: challenge, tabID: nil, windowID: nil, continuation: continuation)
            }
        }
    }
}
