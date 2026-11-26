import SwiftUI
import TildeCore
import TildeDesign

/// Password prompt: "Ask every time" servers, rejected passwords, and secrets that have not synced yet.
struct PasswordPromptSheet: View {
    let request: PasswordRequest
    let onAnswer: (String?, _ saveServer: Bool, _ updateSaved: Bool) -> Void

    @State private var password = ""
    @State private var saveServer = false
    @State private var updateSaved = true
    @FocusState private var focused: Bool

    var body: some View {
        TildeSheet(request.headline, subtitle: request.target.displayString, subtitleIsMono: true, size: .compact, scrolls: false) {
            VStack(alignment: .leading, spacing: TildeSpacing.l) {
                TildeFormSection(footer: request.detail) {
                    TildeTextRow("Password", text: $password, isSecure: true, contentType: .password)
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(submit)
                }
                if request.canUpdateSaved && request.reason == .rejected {
                    TildeFormSection { TildeToggleRow("Update saved password", isOn: $updateSaved) }
                }
                if request.canSaveServer {
                    TildeFormSection { TildeToggleRow("Save server", isOn: $saveServer) }
                }
            }
            .padding(TildeSheetMetrics.padding)
        } actions: {
            TildeCancelButton { onAnswer(nil, false, false) }
            TildeDefaultButton("Connect", action: submit).disabled(password.isEmpty)
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        onAnswer(password, saveServer, updateSaved && request.canUpdateSaved && request.reason == .rejected)
    }
}

/// "Paste 14 lines into prod-api-01?" with a preview of the first 5 lines. Red for production.
struct PasteConfirmationSheet: View {
    let request: PendingPaste
    let onAnswer: (Bool) -> Void

    var body: some View {
        let tone = EnvTone(request.environment)
        let accent = tone == .none ? TildeColor.accent : tone.color
        TildeSheet(
            "Paste \(request.lineCount) \(request.lineCount == 1 ? "line" : "lines") into \(request.serverName)?",
            size: .compact, scrolls: false
        ) {
            VStack(alignment: .leading, spacing: TildeSpacing.m) {
                if tone != .none {
                    HStack(spacing: 8) {
                        EnvBadge(tone)
                        Text(request.serverName).tildeMono(12, relativeTo: .caption).foregroundStyle(TildeColor.text2)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(request.previewLines.enumerated()), id: \.offset) { _, line in
                        Text(line).lineLimit(1).truncationMode(.tail)
                    }
                    if request.truncated {
                        Text("…").foregroundStyle(TildeColor.text3)
                    }
                }
                .tildeMono(12, relativeTo: .caption)
                .foregroundStyle(TildeColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TildeSpacing.m)
                .background(TildeColor.surface, in: RoundedRectangle(cornerRadius: TildeRadius.card))
                .overlay(RoundedRectangle(cornerRadius: TildeRadius.card).stroke(accent.opacity(0.5), lineWidth: 1))

                Text("Each line runs as soon as it arrives.")
                    .tildeText(12, relativeTo: .caption).foregroundStyle(TildeColor.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(TildeSheetMetrics.padding)
        } actions: {
            TildeCancelButton { onAnswer(false) }
            // On a production server a stray Return must not run the pasted lines.
            TildeDefaultButton("Paste", requiresClick: tone == .prod) { onAnswer(true) }
        }
        .presentationDetents([.height(380), .medium])
        .interactiveDismissDisabled()
    }
}

#Preview("Paste confirmation") {
    @Previewable @State var request: PendingPaste?
    Color.clear
        .task {
            _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                request = PendingPaste(lineCount: 14, previewLines: ["sudo systemctl stop api", "rm -rf /var/cache/api", "git pull", "make deploy", "sudo systemctl start api"],
                                       truncated: true, serverName: "prod-api-01", environment: .prod, continuation: c)
            }
        }
        .sheet(item: $request) { PasteConfirmationSheet(request: $0) { _ in } }
}
