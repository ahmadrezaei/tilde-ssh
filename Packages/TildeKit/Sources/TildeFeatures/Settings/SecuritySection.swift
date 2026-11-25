import SwiftUI
import TildeCore
import TildeDesign
import TildeSecurity

/// Settings > Security (docs/DESIGN.md section 4.7): App Lock with Face ID / Touch ID / Optic ID and its timeout,
/// hiding content in the app switcher, strict host checking, and clipboard clearing. Embed it inside a `Section`.
///
/// It finds the lock through `\.tildeAppLock` (set by `AppLockGate`), falling back to `AppLock.current` for the macOS
/// Settings scene, which is a separate SwiftUI scene. Pass `knownHosts` to add the "Known Hosts" row that pushes the
/// list screen.
public struct SecuritySettingsSection<KnownHosts: View>: View {
    @Environment(\.tildeAppLock) private var environmentLock
    private let knownHosts: (() -> KnownHosts)?

    /// - Parameter knownHosts: destination for the "Known Hosts" row; omit to hide the row.
    public init(knownHosts: @escaping () -> KnownHosts) {
        self.knownHosts = knownHosts
    }

    public var body: some View {
        SecurityRows(lock: environmentLock ?? AppLock.current, knownHosts: knownHosts)
    }
}

public extension SecuritySettingsSection where KnownHosts == EmptyView {
    /// The section without a Known Hosts row.
    init() {
        self.knownHosts = nil
    }
}

/// The rows. Separate from the public wrapper so `@Bindable`-style tracking of `SecuritySettings` stays simple.
private struct SecurityRows<KnownHosts: View>: View {
    let lock: AppLock?
    let knownHosts: (() -> KnownHosts)?

    @State private var fallbackSettings = SecuritySettings.shared
    @State private var isChanging = false

    private var settings: SecuritySettings { lock?.settings ?? fallbackSettings }
    private var biometryName: String { lock?.biometry.displayName ?? "Face ID" }

    var body: some View {
        Group {
            appLockRows
            #if os(iOS)
            Toggle(isOn: Bindable(settings).hideContentInSwitcher) {
                row("Hide content in app switcher", detail: "Covers the terminal when you switch apps.")
            }
            #endif
            Toggle(isOn: Bindable(settings).strictHostChecking) {
                row("Strict host checking", detail: "Refuse servers whose host key is not already trusted.")
            }
            Picker(selection: Bindable(settings).clipboardClearSeconds) {
                ForEach(SecuritySettings.clipboardClearChoices, id: \.self) { seconds in
                    Text(Self.clipboardTitle(seconds)).tag(seconds)
                }
            } label: {
                row("Clear clipboard", detail: "After copying a private key or password.")
            }
            if let knownHosts {
                NavigationLink {
                    knownHosts()
                } label: {
                    Label("Known Hosts", systemImage: "checkmark.shield")
                }
            }
        }
    }

    @ViewBuilder private var appLockRows: some View {
        let available = lock?.isAvailable ?? true
        Toggle(isOn: Binding(
            get: { settings.appLockEnabled },
            set: { newValue in setAppLock(newValue) }
        )) {
            row("App Lock with \(biometryName)", detail: available
                ? "Ask for \(biometryName) or your passcode to open Tilde. Open sessions stay connected."
                : "Set a passcode on this device to use App Lock.")
        }
        .disabled(!available || isChanging)
        .accessibilityHint("Requires authentication to change")

        if settings.appLockEnabled {
            Picker("Lock", selection: Bindable(settings).lockTimeout) {
                ForEach(AppLockTimeout.allCases) { Text($0.title).tag($0) }
            }
        }
    }

    private func row(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(TildeColor.text3)
        }
    }

    /// Turning the lock on or off asks the owner to authenticate first; the toggle snaps back if they cancel.
    private func setAppLock(_ enabled: Bool) {
        guard let lock else {
            settings.appLockEnabled = enabled  // no lock object (previews): just store the preference
            return
        }
        isChanging = true
        Task {
            await lock.setEnabled(enabled)
            isChanging = false
        }
    }

    private static func clipboardTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Never"
        case 30: "After 30 seconds"
        case 60: "After 1 minute"
        case 120: "After 2 minutes"
        case 300: "After 5 minutes"
        default: "After \(seconds) seconds"
        }
    }
}

#Preview("SecuritySettingsSection") {
    NavigationStack {
        List {
            Section { SecuritySettingsSection(knownHosts: { Text("Known hosts") }) } header: { Text("Security").tildeSectionHeader() }
        }
        .navigationTitle("Settings")
    }
    .environment(\.tildeAppLock, AppLock(settings: SecuritySettings(defaults: UserDefaults(suiteName: "tilde.preview")!), authenticator: StubAuthenticator()))
    .preferredColorScheme(.dark)
}
