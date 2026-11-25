import SwiftUI
import TildeCore
import TildeDesign
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Wraps the app's root content and covers it with a lock screen while `lock.isLocked` is true.
/// Live sessions stay connected while locked; only the UI is covered (and made untouchable, and the keyboard is
/// dismissed so hardware keystrokes cannot reach a terminal behind the cover).
///
/// The cover is shown twice on purpose: as a sibling of the content, and in a **separate overlay window above
/// everything** (`LockOverlayPresenter`), because sheets, full-screen covers, popovers and alerts are presented above
/// any view in the root hierarchy and would otherwise stay readable while locked.
///
/// With a real `AppLock` the gate also feeds it the scene phase (re-lock timeout) and shows the privacy cover
/// while the app is in the app switcher. It injects the lock into the environment as `\.tildeAppLock`.
public struct AppLockGate<Content: View>: View {
    private let lock: any AppLocking
    private let content: Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasAutoPrompted = false
    @State private var presenter: LockOverlayPresenter?
    /// Identifies this scene to the lock, which combines the phase of every scene (iPad windows, Mac windows).
    @State private var sceneID = UUID()

    public init(lock: any AppLocking, @ViewBuilder content: () -> Content) {
        self.lock = lock
        self.content = content()
    }

    private var concreteLock: AppLock? { lock as? AppLock }
    private var isCovered: Bool { concreteLock?.isPrivacyCoverVisible ?? lock.isLocked }
    private var shouldPrompt: Bool { lock.isLocked && scenePhase == .active }

    public var body: some View {
        ZStack {
            content
                .environment(\.tildeAppLock, concreteLock)
                .allowsHitTesting(!isCovered)
                .accessibilityHidden(isCovered)
                .disabled(lock.isLocked)
            if isCovered {
                LockCoverHost(lock: lock)
                    .transition(.opacity)
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            concreteLock?.sceneDidChange(AppLockPhase(phase), scene: sceneID)
            syncOverlay()
        }
        .onChange(of: isCovered, initial: true) { _, _ in syncOverlay() }
        .onChange(of: lock.isLocked, initial: true) { _, locked in
            if locked {
                hasAutoPrompted = false
                resignKeyboardFocus()
            }
        }
        .onChange(of: shouldPrompt, initial: true) { _, prompt in
            // Ask once per lock; after a cancel the user taps the button.
            guard prompt, !hasAutoPrompted else { return }
            hasAutoPrompted = true
            Task { _ = await lock.unlock() }
        }
        .onDisappear {
            concreteLock?.sceneDidDisappear(sceneID)
            presenter?.setVisible(false)
        }
    }

    /// Shows or removes the overlay window to match the lock state (and picks up scenes that appeared since).
    private func syncOverlay() {
        if presenter == nil {
            let lock = lock
            presenter = LockOverlayPresenter { AnyView(LockCoverHost(lock: lock).preferredColorScheme(.dark)) }
        }
        presenter?.setVisible(isCovered)
    }

    private func resignKeyboardFocus() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #elseif canImport(AppKit)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }
}

/// Reads the lock's state itself, so the same view works inside the hierarchy and in the overlay window.
struct LockCoverHost: View {
    let lock: any AppLocking

    var body: some View {
        let concrete = lock as? AppLock
        LockCover(
            isLocked: lock.isLocked,
            biometry: concrete?.biometry ?? .none,
            showsFailure: concrete?.lastAttemptFailed ?? false,
            isBusy: concrete?.isAuthenticating ?? false,
            unlock: { Task { _ = await lock.unlock() } }
        )
    }
}

/// The lock screen / privacy cover.
private struct LockCover: View {
    let isLocked: Bool
    let biometry: BiometryKind
    let showsFailure: Bool
    let isBusy: Bool
    let unlock: () -> Void

    var body: some View {
        ZStack {
            TildeColor.bg.ignoresSafeArea()
            VStack(spacing: TildeSpacing.l) {
                Text("~")
                    .font(TildeFont.mono(88, weight: .heavy))
                    .foregroundStyle(TildeColor.accent)
                    .accessibilityHidden(true)
                if isLocked {
                    VStack(spacing: TildeSpacing.xs) {
                        Text("Tilde is locked")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(TildeColor.text)
                        Text("Open sessions stay connected.")
                            .font(.system(size: 14))
                            .foregroundStyle(TildeColor.text2)
                    }
                    Button(action: unlock) {
                        Label("Unlock with \(biometry.displayName)", systemImage: biometry.symbolName)
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, TildeSpacing.l)
                            .frame(minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TildeColor.accentStrong)
                    .controlSize(.large)
                    .disabled(isBusy)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint("Shows the system authentication prompt")
                    if showsFailure {
                        Text("Authentication failed. Try again.")
                            .font(.system(size: 13))
                            .foregroundStyle(TildeColor.danger)
                    }
                }
            }
            .padding(TildeSpacing.xl)
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Locked") {
    AppLockGate(lock: FakeAppLock(isLocked: true)) {
        Text("Secret terminal").foregroundStyle(.white)
    }
    .preferredColorScheme(.dark)
}
