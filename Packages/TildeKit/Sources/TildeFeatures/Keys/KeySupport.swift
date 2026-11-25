import Foundation
import SwiftData
import SwiftUI
import TildeCore
import TildeDesign
import TildeSecurity
import TildeStore
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Labels

extension SSHKeyRecord {
    /// The algorithm, or `nil` for an unknown raw value written by a newer app version.
    var algorithm: SSHKeyAlgorithm? { SSHKeyAlgorithm(rawValue: algorithmRaw) }

    /// `ED25519`, `ECDSA-P256`, `RSA-4096`: the badge text.
    var typeBadge: String {
        switch algorithm {
        case .ed25519: "ED25519"
        case .ecdsaP256: "ECDSA-P256"
        case .ecdsaP384: "ECDSA-P384"
        case .ecdsaP521: "ECDSA-P521"
        case .rsa: "RSA-\(bits ?? 0)"
        case nil: algorithmRaw.uppercased()
        }
    }

    /// Spoken form of the badge for VoiceOver.
    var typeSpokenName: String {
        switch algorithm {
        case .ed25519: "Ed25519"
        case .ecdsaP256: "ECDSA P-256"
        case .ecdsaP384: "ECDSA P-384"
        case .ecdsaP521: "ECDSA P-521"
        case .rsa: "RSA \(bits ?? 0) bit"
        case nil: algorithmRaw
        }
    }

    /// `SHA256:4f+HqTn1…Vw0`
    var shortFingerprint: String { KeyFingerprint.abbreviated(fingerprintSHA256) }

    var serverCount: Int { servers?.count ?? 0 }

    var serverCountText: String { serverCount == 1 ? "1 server" : "\(serverCount) servers" }

    var secretRef: SecretRef { SecretRef(kind: .privateKey, id: privateSecretID) }

    /// `Generated 2026-11-02 · iCloud Keychain`
    var originSubtitle: String {
        let verb = sourceRaw == "imported" ? "Imported" : "Generated"
        let date = createdAt.formatted(.iso8601.year().month().day())
        return "\(verb) \(date) · \(isSynchronizable ? "iCloud Keychain" : "This device only")"
    }
}

/// The name of this device as shown to the user.
enum DeviceInfo {
    /// `iPhone 16 Pro` / `MacBook Pro`. Stored as `originDeviceName` for device-only keys.
    @MainActor static var displayName: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #elseif canImport(AppKit)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #else
        "This device"
        #endif
    }

    /// A short slug for default key names: `iphone`, `macbook-pro`.
    @MainActor static var slug: String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var slug = ""
        for character in displayName.lowercased() {
            if allowed.contains(character) { slug.append(character) } else if !slug.hasSuffix("-"), !slug.isEmpty { slug.append("-") }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "device" : slug
    }
}

// MARK: - Persistence helpers

/// Key creation and deletion: the private bytes go to the Keychain, only metadata to SwiftData.
@MainActor
enum KeyStorage {
    enum StorageError: LocalizedError {
        case keychain
        case save

        var errorDescription: String? {
            switch self {
            case .keychain: "The key could not be saved to the Keychain."
            case .save: "The key could not be saved."
            }
        }
    }

    /// Stores `material` in the Keychain and inserts the matching record. Rolls the Keychain write back if saving the
    /// record fails, so there are no orphans.
    static func save(
        info: PublicKeyInfo,
        material: PrivateKeyMaterial,
        name: String,
        source: String,
        synchronizable: Bool,
        services: TildeServices,
        context: ModelContext
    ) throws -> SSHKeyRecord {
        let record = SSHKeyRecord(
            name: name,
            algorithmRaw: info.algorithm.rawValue,
            publicKeyOpenSSH: info.openSSH,
            fingerprintSHA256: info.fingerprintSHA256,
            comment: info.comment
        )
        record.bits = info.bits
        record.sourceRaw = source
        record.isSynchronizable = synchronizable
        record.originDeviceName = DeviceInfo.displayName
        let ref = record.secretRef
        do {
            try services.secretStore.write(material.openSSHBytes, for: ref, label: "Tilde: private key \(name)", synchronizable: synchronizable)
        } catch {
            throw StorageError.keychain
        }
        context.insert(record)
        do {
            try context.save()
        } catch {
            context.delete(record)
            try? services.secretStore.delete(ref)
            throw StorageError.save
        }
        return record
    }

    /// Deletes the Keychain items and then the record, in one user action (docs/DESIGN.md section 6.2).
    static func delete(_ record: SSHKeyRecord, services: TildeServices, context: ModelContext) throws {
        do {
            try services.secretStore.delete(record.secretRef)
            try services.secretStore.delete(SecretRef(kind: .keyPassphrase, id: record.privateSecretID))
        } catch {
            throw StorageError.keychain
        }
        context.delete(record)
        try context.save()
    }

    /// `true` when the private key is on this device (it may be missing while iCloud Keychain catches up, or
    /// for a device-only key created elsewhere).
    static func hasPrivateKey(_ record: SSHKeyRecord, services: TildeServices) -> Bool {
        guard let refs = try? services.secretStore.allRefs() else { return true }  // unknown: do not alarm
        return refs.contains(record.secretRef)
    }
}

// MARK: - Server snapshots

extension ServerSnapshot {
    /// Builds the engine snapshot for a stored server (the store layer's own mapper may replace this later).
    @MainActor
    init(keyFlowModel server: Server) {
        let auth = AuthMethod(rawValue: server.authMethodRaw) ?? .key
        var jump: JumpSnapshot?
        if let hop = server.jumpServer {
            jump = JumpSnapshot(
                target: ConnectionTarget(host: hop.host, port: hop.port, username: hop.username),
                auth: AuthMethod(rawValue: hop.authMethodRaw) ?? .key,
                keyID: hop.key?.privateSecretID,
                passwordSecretID: hop.passwordSecretID)
        }
        self.init(
            id: server.id,
            name: server.name.isEmpty ? server.host : server.name,
            target: ConnectionTarget(host: server.host, port: server.port, username: server.username),
            auth: auth,
            keyID: server.key?.privateSecretID,
            passwordSecretID: server.passwordSecretID,
            environment: ServerEnvironment(rawValue: server.environmentRaw) ?? .none,
            jump: jump,
            startupCommand: nil,
            autoTmux: false,
            tmuxSessionName: server.tmuxSessionName,
            keepAliveSeconds: server.keepAliveSeconds,
            termType: server.termType,
            envVars: [:])
    }
}

// MARK: - Documents and transferables

/// A text file for `.fileExporter` (private or public key).
struct KeyFileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A `.pub` file for the share sheet.
struct PublicKeyFile: Transferable {
    let fileName: String
    let line: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { item in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(item.fileName)
            try Data((item.line + "\n").utf8).write(to: url)
            return SentTransferredFile(url)
        }
    }
}

// MARK: - Styling

extension View {
    /// Dark-first list/form chrome shared by the key screens.
    func tildeFormStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(TildeColor.bg)
    }
}

/// The key glyph in a rounded square (the mockup's `.kicon`).
struct KeyGlyph: View {
    var highlighted = false

    var body: some View {
        Image(systemName: "key.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(TildeColor.accent)
            .frame(width: 30, height: 30)
            .background(highlighted ? TildeColor.accentSoft : TildeColor.surface3, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

/// `ED25519` in a small bordered capsule (the mockup's `.ktype`).
struct TypeBadge: View {
    let text: String
    var tinted = false

    var body: some View {
        Text(text)
            .font(TildeFont.mono(10, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(tinted ? TildeColor.accent : TildeColor.text2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(TildeColor.surface3, in: RoundedRectangle(cornerRadius: TildeRadius.badge))
            .overlay(RoundedRectangle(cornerRadius: TildeRadius.badge).stroke(tinted ? TildeColor.accent.opacity(0.4) : TildeColor.border, lineWidth: TildeSpacing.hairline))
            .accessibilityHidden(true)
    }
}

/// The sync glyph: cloud = iCloud Keychain, phone/laptop = this device only.
struct SyncGlyph: View {
    let record: SSHKeyRecord

    var body: some View {
        Image(systemName: record.isSynchronizable ? "icloud" : deviceSymbol)
            .font(.system(size: 14))
            .foregroundStyle(TildeColor.text3)
            .accessibilityLabel(record.isSynchronizable ? "Synced with iCloud Keychain" : "This device only")
    }

    private var deviceSymbol: String {
        #if os(iOS)
        "iphone"
        #else
        "laptopcomputer"
        #endif
    }
}
