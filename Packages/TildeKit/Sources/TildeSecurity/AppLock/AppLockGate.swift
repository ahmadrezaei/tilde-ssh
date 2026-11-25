import SwiftUI
import TildeCore

/// Wraps the app's root content and covers it with a lock screen while `lock.isLocked` is true.
/// Live sessions stay connected while locked; only the UI is covered.
///
/// Placeholder: WS3 adds the lock UI, the privacy cover for the app switcher and the scene-phase timeout.
/// The signature is the contract used by `TildeApp` (WS5).
public struct AppLockGate<Content: View>: View {
    private let lock: any AppLocking
    private let content: Content

    public init(lock: any AppLocking, @ViewBuilder content: () -> Content) {
        self.lock = lock
        self.content = content()
    }

    public var body: some View {
        ZStack {
            content
            if lock.isLocked {
                Rectangle().fill(.black)
                    .overlay {
                        Button("Unlock") { Task { _ = await lock.unlock() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .ignoresSafeArea()
            }
        }
    }
}
