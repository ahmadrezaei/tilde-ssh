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
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .focused($focused)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .tildeMono(15)
                } header: {
                    Text(request.target.displayString).tildeMono(12, relativeTo: .caption).textCase(nil)
                } footer: {
                    Text(request.detail)
                }
                if request.canUpdateSaved && request.reason == .rejected {
                    Section { Toggle("Update saved password", isOn: $updateSaved) }
                }
                if request.canSaveServer {
                    Section { Toggle("Save server", isOn: $saveServer) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(TildeColor.bg)
            .navigationTitle(request.headline)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onAnswer(nil, false, false) } }
                ToolbarItem(placement: .confirmationAction) { Button("Connect", action: submit).disabled(password.isEmpty) }
            }
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
    let request: PasteRequest
    let onAnswer: (Bool) -> Void

    var body: some View {
        let tone = EnvTone(request.environment)
        let accent = tone == .none ? TildeColor.accent : tone.color
        VStack(alignment: .leading, spacing: TildeSpacing.l) {
            HStack(spacing: 8) {
                Text("Paste \(request.lineCount) \(request.lineCount == 1 ? "line" : "lines") into \(request.serverName)?")
                    .tildeText(18, weight: .bold, relativeTo: .headline)
                    .foregroundStyle(TildeColor.text)
                EnvBadge(tone)
            }
            .accessibilityElement(children: .combine)

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
            .background(TildeColor.bg, in: RoundedRectangle(cornerRadius: TildeRadius.card))
            .overlay(RoundedRectangle(cornerRadius: TildeRadius.card).stroke(accent.opacity(0.4), lineWidth: 1))

            Text("Each line runs as soon as it arrives.").tildeText(12, relativeTo: .caption).foregroundStyle(TildeColor.text3)

            HStack(spacing: TildeSpacing.s) {
                Button("Cancel") { onAnswer(false) }.buttonStyle(.tildeSecondary).keyboardShortcut(.cancelAction)
                Button("Paste") { onAnswer(true) }.buttonStyle(.tildePrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(TildeSpacing.l)
        .background(TildeColor.surface)
        .presentationDetents([.height(380), .medium])
        .interactiveDismissDisabled()
    }
}

#Preview("Paste confirmation") {
    @Previewable @State var request: PasteRequest?
    Color.clear
        .task {
            _ = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                request = PasteRequest(lineCount: 14, previewLines: ["sudo systemctl stop api", "rm -rf /var/cache/api", "git pull", "make deploy", "sudo systemctl start api"],
                                       truncated: true, serverName: "prod-api-01", environment: .prod, continuation: c)
            }
        }
        .sheet(item: $request) { PasteConfirmationSheet(request: $0) { _ in } }
}
