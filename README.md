# Tilde: SSH Client & Terminal

A fast, native, open-source SSH client for iPhone, iPad and Mac. Dark by default, keyboard-first, built for people who get paged.

> Status: early scaffolding. See [`docs/DESIGN.md`](docs/DESIGN.md) for the full design and [`docs/CONTRACTS-NOTES.md`](docs/CONTRACTS-NOTES.md) for the frozen module contracts.

- Servers sync over iCloud (SwiftData + CloudKit); passwords and keys stay in iCloud Keychain.
- Ed25519 key generation, key import, host key verification (TOFU), jump host.
- A real SSH keyboard on iOS and iPadOS; tabs and shortcuts on iPad and Mac.
- No account, no analytics.

## Requirements

- Xcode 27.1 (Swift 6.4), iOS / iPadOS 26+, macOS 26+
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), only if you change `project.yml`

## Layout

```
App/                 App targets: Shared/ (TildeApp, AppEnvironment), iOS/, macOS/, Resources/
Config/Shared.xcconfig   Bundle id, CloudKit container, keychain group, team (fork-friendly)
Packages/TildeKit/   All logic: TildeCore, TildeStore, TildeSecurity, TildeSSH, TildeTerminal, TildeDesign, TildeFeatures
docs/  design/       Design spec, mockups, icon
project.yml          XcodeGen spec for Tilde.xcodeproj
```

## Build

```sh
# Package (headless, no simulator needed)
cd Packages/TildeKit && swift build && swift test

# Apps
xcodebuild -project Tilde.xcodeproj -scheme Tilde-iOS   -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Tilde.xcodeproj -scheme Tilde-macOS -destination 'platform=macOS'                -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build
```

`-skipPackagePluginValidation` is needed on the command line because SwiftTerm ships a build-tool plugin
(`SwiftTermBuildInfoPlugin`); in the Xcode UI, choose "Trust & Enable" once when prompted.

`Tilde.xcodeproj` is generated from `project.yml` and committed. You almost never need to regenerate it:
code lives in the Swift package, and the `App/` folders are synchronized folders, so adding files needs no
project edit. If you edit `project.yml`, run `xcodegen generate`.

To run on a device or use iCloud, set your own `DEVELOPMENT_TEAM` and identifiers in `Config/Shared.xcconfig`
(or a git-ignored `Config/Local.xcconfig`).

## License

[Apache-2.0](LICENSE). The name "Tilde" and the app icon are not covered by the license grant (see section 6 of the license).
