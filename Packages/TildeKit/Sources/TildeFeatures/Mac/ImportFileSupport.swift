import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if canImport(Darwin)
import Darwin
#endif

/// A file the user picked, with its contents already read inside the sandbox grant.
struct PickedFile: Sendable {
    /// `lastPathComponent`, for display.
    let name: String
    let data: Data

    /// The contents as text. Tries UTF-8, then falls back to Latin-1 so a stray byte never blocks an import.
    var text: String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

enum ImportFileError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case tooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): "Couldn't read \(name)."
        case .tooLarge(let bytes): "That file is \(bytes / 1024) KB, which is too large to be an SSH file."
        }
    }
}

enum ImportFiles {
    /// Config files and key files are small. Anything bigger is almost certainly the wrong file.
    static let maxBytes = 4 * 1024 * 1024

    /// Reads a user-selected file under its security-scoped grant (App Sandbox: `user-selected.read-only`).
    static func read(_ url: URL) throws -> PickedFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ImportFileError.unreadable(url.lastPathComponent)
        }
        guard data.count <= maxBytes else { throw ImportFileError.tooLarge(data.count) }
        return PickedFile(name: url.lastPathComponent, data: data)
    }

    /// The user's real `~/.ssh`. Inside the App Sandbox, `NSHomeDirectory()` is the app container, so the home
    /// directory is read from the password database. Used only as the file dialog's starting folder: the
    /// sandbox still requires the user to pick the file.
    static var sshDirectory: URL? {
        #if os(macOS)
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true).appendingPathComponent(".ssh", isDirectory: true)
        #else
        return nil
        #endif
    }
}

extension View {
    /// Starts file dialogs in `~/.ssh` (and shows hidden files) on macOS; a no-op elsewhere.
    @ViewBuilder
    func startInSSHDirectory() -> some View {
        #if os(macOS)
        if let directory = ImportFiles.sshDirectory {
            self
                .fileDialogDefaultDirectory(directory)
                .fileDialogBrowserOptions([.includeHiddenFiles])
        } else {
            self.fileDialogBrowserOptions([.includeHiddenFiles])
        }
        #else
        self
        #endif
    }
}

/// A check box that works the same on iOS and macOS (the system `.checkbox` style is macOS only).
struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? Text("Selected") : Text("Not selected"))
    }
}
