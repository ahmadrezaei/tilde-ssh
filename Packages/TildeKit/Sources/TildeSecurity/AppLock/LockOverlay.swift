import SwiftUI
import TildeCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Puts the lock screen / privacy cover **above everything the app shows**, including sheets, full-screen covers,
/// popovers and alerts, which SwiftUI presents above any view in the root hierarchy.
///
/// - iOS / iPadOS: one extra `UIWindow` per connected window scene at `windowLevel = .alert + 1`.
/// - macOS: a borderless child window laid over every visible window, sheets included.
///
/// `AppLockGate` drives it from the lock state and the scene phase.
@MainActor
final class LockOverlayPresenter {
    private let content: () -> AnyView
    #if canImport(UIKit)
    private var windows: [ObjectIdentifier: UIWindow] = [:]
    #elseif canImport(AppKit)
    private var overlays: [ObjectIdentifier: (target: NSWindow, overlay: NSWindow)] = [:]
    private var observers: [NSObjectProtocol] = []
    private var isVisible = false
    #endif

    init(content: @escaping () -> AnyView) {
        self.content = content
    }

    var isPresenting: Bool {
        #if canImport(UIKit)
        !windows.isEmpty
        #elseif canImport(AppKit)
        !overlays.isEmpty
        #endif
    }

    /// Shows or removes the overlay. Call again whenever scenes or windows may have changed while it is visible.
    func setVisible(_ visible: Bool) {
        #if canImport(UIKit)
        visible ? syncWindows() : tearDownWindows()
        #elseif canImport(AppKit)
        isVisible = visible
        visible ? syncOverlays() : tearDownOverlays()
        #endif
    }

    // MARK: iOS

    #if canImport(UIKit)
    private func syncWindows() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState != .unattached }
        let live = Set(scenes.map(ObjectIdentifier.init))
        for (id, window) in windows where !live.contains(id) {
            window.isHidden = true
            windows[id] = nil
        }
        for scene in scenes where windows[ObjectIdentifier(scene)] == nil {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level.alert + 1
            let host = UIHostingController(rootView: content())
            host.view.backgroundColor = .clear
            window.rootViewController = host
            // Key, so hardware keystrokes cannot reach a terminal behind the cover.
            window.makeKeyAndVisible()
            windows[ObjectIdentifier(scene)] = window
        }
    }

    private func tearDownWindows() {
        for window in windows.values {
            window.isHidden = true
            window.rootViewController = nil
        }
        windows.removeAll()
    }
    #endif

    // MARK: macOS

    #if canImport(AppKit)
    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private func syncOverlays() {
        if observers.isEmpty { observe() }
        let targets = NSApp.windows.filter { window in
            !(window is OverlayWindow) && window.isVisible && window.frame.width > 40 && window.frame.height > 40
        }
        let live = Set(targets.map(ObjectIdentifier.init))
        for (id, pair) in overlays where !live.contains(id) {
            remove(pair)
            overlays[id] = nil
        }
        for target in targets {
            let id = ObjectIdentifier(target)
            if let pair = overlays[id] {
                pair.overlay.setFrame(target.frame, display: true)
                continue
            }
            let overlay = OverlayWindow(contentRect: target.frame, styleMask: .borderless, backing: .buffered, defer: false)
            overlay.isReleasedWhenClosed = false
            overlay.isOpaque = true
            overlay.backgroundColor = .black
            overlay.hasShadow = false
            overlay.level = target.level
            overlay.contentView = NSHostingView(rootView: content())
            target.addChildWindow(overlay, ordered: .above)
            overlay.makeKeyAndOrderFront(nil)
            overlays[id] = (target, overlay)
        }
    }

    private func tearDownOverlays() {
        for pair in overlays.values { remove(pair) }
        overlays.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func remove(_ pair: (target: NSWindow, overlay: NSWindow)) {
        pair.target.removeChildWindow(pair.overlay)
        pair.overlay.orderOut(nil)
        pair.overlay.contentView = nil
    }

    /// Keeps the overlays in step while visible: new sheets or windows get covered, resized windows stay covered.
    private func observe() {
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didBecomeMainNotification,
            NSWindow.didUpdateNotification, NSWindow.willBeginSheetNotification, NSApplication.didBecomeActiveNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let source = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated {
                    guard let self, self.isVisible else { return }
                    if let source, self.overlays.values.contains(where: { ObjectIdentifier($0.overlay) == source }) { return }
                    if name == NSWindow.didUpdateNotification, self.overlays.count == NSApp.windows.filter({ $0.isVisible && !($0 is OverlayWindow) }).count { return }
                    self.syncOverlays()
                }
            }
        }
    }
    #endif
}
