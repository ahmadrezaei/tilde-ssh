import CloudKit
import CoreData
import Foundation
import Observation
import SwiftData

/// The iCloud account state, reduced from `CKAccountStatus`.
public enum ICloudAccountStatus: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
    /// Not asked yet, or CloudKit is not usable in this build.
    case unknown
}

/// What the Settings > Sync screen shows.
public enum SyncStatus: Equatable, Sendable {
    /// The store is local-only: sync is off, the build has no iCloud entitlement, or CloudKit could not start.
    case disabled
    case noAccount
    case restricted
    case temporarilyUnavailable
    /// Syncing is on and the last import/export succeeded (or nothing has happened yet).
    case upToDate
    /// An import or export is running.
    case syncing
    /// The last import or export failed. The text is CloudKit's own description; it never contains secrets
    /// (no secret is ever in the synced store).
    case error(String)
}

/// A reduced `NSPersistentCloudKitContainer.Event`, so it can cross actors and be created in tests.
public struct SyncEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case setup, `import`, export }
    public var kind: Kind
    /// `nil` while the event is still running.
    public var endDate: Date?
    public var succeeded: Bool
    public var errorDescription: String?

    public init(kind: Kind, endDate: Date?, succeeded: Bool, errorDescription: String? = nil) {
        self.kind = kind
        self.endDate = endDate
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }
}

/// Observes the iCloud account and the CloudKit mirroring events and publishes one simple `SyncStatus`.
///
/// ```swift
/// let monitor = SyncStatusMonitor(mode: bootstrap.mode)
/// monitor.start()
/// ```
@MainActor
@Observable
public final class SyncStatusMonitor {
    public private(set) var status: SyncStatus
    public private(set) var accountStatus: ICloudAccountStatus = .unknown
    /// The end of the last successful import or export.
    public private(set) var lastSyncDate: Date?
    /// The user's current "Sync on/off" choice. Update it when the switch changes; the container only reads it
    /// at launch, so a difference from the launch value means a restart is needed.
    public var syncPreference: Bool

    /// `true` when `syncPreference` differs from what the store was opened with, so Settings shows
    /// "Restart Tilde to apply". It does not depend on the iCloud account (a signed-out user already has the
    /// CloudKit store, which syncs once they sign in) and cannot loop: a build without CloudKit, or a failed
    /// CloudKit start, leaves both values equal.
    public var needsRestartToSync: Bool { mode != .inMemory && syncPreference != launchSyncPreference }

    @ObservationIgnored private let mode: StoreMode
    @ObservationIgnored private let launchSyncPreference: Bool
    @ObservationIgnored private let accountProvider: @Sendable () async -> ICloudAccountStatus
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var activeEvents = 0

    /// - Parameters:
    ///   - mode: the mode the container actually runs in (`StoreBootstrap.mode`).
    ///   - syncEnabled: the user's sync switch at launch.
    ///   - accountProvider: how to read the account status; defaults to `CKContainer.accountStatus`. The
    ///     default never creates a `CKContainer` unless the store is a CloudKit store or
    ///     `CloudKitAvailability` says this build is entitled (creating one without the entitlement can abort).
    public init(
        mode: StoreMode,
        syncEnabled: Bool = true,
        accountProvider: (@Sendable () async -> ICloudAccountStatus)? = nil
    ) {
        self.mode = mode
        self.launchSyncPreference = syncEnabled
        self.syncPreference = syncEnabled
        if let accountProvider {
            self.accountProvider = accountProvider
        } else {
            let containerID: String? = {
                if case .cloudKit(let id) = mode { return id }
                return CloudKitAvailability.canUseCloudKit(containerID: ModelContainerFactory.defaultCloudKitContainerID)
                    ? ModelContainerFactory.defaultCloudKitContainerID : nil
            }()
            self.accountProvider = { await Self.readAccountStatus(containerID: containerID) }
        }
        self.status = mode.isSyncing ? .upToDate : .disabled
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Reads the account status and starts observing account changes and mirroring events.
    public func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            let reduced = SyncEvent(event)
            Task { @MainActor in self?.apply(reduced) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in await self?.refreshAccountStatus() }
        })
        Task { await refreshAccountStatus() }
    }

    /// Re-reads the iCloud account status.
    public func refreshAccountStatus() async {
        let account = await accountProvider()
        apply(account: account)
    }

    // MARK: State machine (internal for tests)

    func apply(account: ICloudAccountStatus) {
        accountStatus = account
        recomputeStatus(lastError: nil)
    }

    func apply(_ event: SyncEvent) {
        if event.endDate == nil {
            activeEvents += 1
            status = .syncing
            return
        }
        activeEvents = max(0, activeEvents - 1)
        if event.succeeded {
            if event.kind != .setup, let end = event.endDate { lastSyncDate = max(lastSyncDate ?? .distantPast, end) }
            recomputeStatus(lastError: nil)
        } else {
            recomputeStatus(lastError: event.errorDescription ?? "Sync failed.")
        }
    }

    private func recomputeStatus(lastError: String?) {
        guard mode.isSyncing else {
            status = .disabled
            return
        }
        switch accountStatus {
        case .noAccount: status = .noAccount
        case .restricted: status = .restricted
        case .temporarilyUnavailable: status = .temporarilyUnavailable
        case .available, .couldNotDetermine, .unknown:
            if let lastError { status = .error(lastError) } else { status = activeEvents > 0 ? .syncing : .upToDate }
        }
    }

    private static func readAccountStatus(containerID: String?) async -> ICloudAccountStatus {
        guard let containerID else { return .unknown }
        do {
            switch try await CKContainer(identifier: containerID).accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermine
            @unknown default: return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }
}

extension SyncEvent {
    init(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: Kind
        switch event.type {
        case .setup: kind = .setup
        case .import: kind = .import
        case .export: kind = .export
        @unknown default: kind = .setup
        }
        self.init(kind: kind, endDate: event.endDate, succeeded: event.succeeded, errorDescription: event.error?.localizedDescription)
    }
}

/// Record counts for the Sync screen ("42 servers, 5 keys").
public struct StoreCounts: Equatable, Sendable {
    public var servers: Int
    public var keys: Int
    public var snippets: Int
    public var knownHosts: Int

    public init(servers: Int = 0, keys: Int = 0, snippets: Int = 0, knownHosts: Int = 0) {
        self.servers = servers
        self.keys = keys
        self.snippets = snippets
        self.knownHosts = knownHosts
    }

    /// Counts the records in `context`.
    public static func fetch(in context: ModelContext) throws -> StoreCounts {
        StoreCounts(
            servers: try context.fetchCount(FetchDescriptor<Server>()),
            keys: try context.fetchCount(FetchDescriptor<SSHKeyRecord>()),
            snippets: try context.fetchCount(FetchDescriptor<Snippet>()),
            knownHosts: try context.fetchCount(FetchDescriptor<KnownHost>())
        )
    }
}
