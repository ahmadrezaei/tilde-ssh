import CoreData
import Foundation
import SwiftData

/// Runs the `Deduplicator` at launch and after every remote import, debounced (default 2 s) so a burst of
/// CloudKit imports causes one pass. Create it once next to the container and call `start()`.
@MainActor
public final class DeduplicationCoordinator {
    private let container: ModelContainer
    private let debounce: Duration
    private var observer: (any NSObjectProtocol)?
    private var pending: Task<Void, Never>?

    /// The result of the most recent pass.
    public private(set) var lastReport: DeduplicationReport?

    public init(container: ModelContainer, debounce: Duration = .seconds(2)) {
        self.container = container
        self.debounce = debounce
    }

    isolated deinit {
        pending?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Starts observing remote changes and schedules a pass for launch. Calling it twice is harmless.
    public func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        }
        schedule()
    }

    /// Stops observing and cancels a pending pass.
    public func stop() {
        pending?.cancel()
        pending = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Schedules a pass after the debounce interval, replacing a pass that is already waiting.
    public func schedule() {
        pending?.cancel()
        pending = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            runNow()
        }
    }

    /// Runs a pass immediately on the main context.
    @discardableResult
    public func runNow() -> DeduplicationReport? {
        do {
            let report = try Deduplicator.run(in: container.mainContext)
            lastReport = report
            return report
        } catch {
            return nil
        }
    }
}
