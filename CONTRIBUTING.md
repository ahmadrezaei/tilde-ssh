# Contributing to Tilde

Thanks for helping. This file covers how the code is organized, how to run things, and what makes a pull request easy to merge.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Before you start

- **Small fixes** (typos, bugs with an obvious fix): open a pull request directly.
- **Features and larger changes:** open an issue first so we can agree on the shape. [`docs/DESIGN.md`](docs/DESIGN.md) is the source of truth for behavior, naming and visuals; if your idea changes the design, say so in the issue.
- **Good first issues** are labeled `good first issue`.

## Setup

Requirements: Xcode 27.1 (Swift 6.4), macOS 26 or later. [XcodeGen](https://github.com/yonaskolb/XcodeGen) only if you edit `project.yml`.

```sh
git clone https://github.com/ahmadrezaei/tilde-ssh.git
cd tilde-ssh/Packages/TildeKit
swift build
swift test
```

The first dependency resolve clones a few hundred MB (SwiftTerm pulls in swift-png). Do not run two resolves at once.

Build the apps:

```sh
xcodebuild -project Tilde.xcodeproj -scheme Tilde-macOS -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Tilde.xcodeproj -scheme Tilde-iOS -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build
```

SwiftTerm ships a SwiftPM build-tool plugin, which is why the `-skip…Validation` flags are needed outside Xcode. In Xcode, click **Trust & Enable** once.

To run on a device or with iCloud, put your own `DEVELOPMENT_TEAM` and identifiers in `Config/Local.xcconfig` (git-ignored). Never commit a team ID of your own.

## How the code is organized

Logic lives in the `TildeKit` package; the app targets are thin. The module graph is in the [README](README.md#architecture).

| Module | What goes there | Depends on |
|---|---|---|
| `TildeCore` | Value types, protocols (the contracts), mocks | nothing |
| `TildeDesign` | Color and type tokens, small components | nothing |
| `TildeStore` | SwiftData schema, repositories, deduplication | Core |
| `TildeSecurity` | Keychain, key parsing and generation, app lock | Core, Citadel (crypto only) |
| `TildeSSH` | Session engine, host key validation, parsers | Core, Citadel |
| `TildeTerminal` | Terminal views, key bar, themes | Core, Design, SwiftTerm |
| `TildeFeatures` | Screens, navigation, Mac menus | everything above |

Rules that keep this workable:

1. **Code against `TildeCore` protocols**, and use the mocks (`TildeServices.preview`, `FakeSessionEngine`, ...) in previews and tests. Do not import a sibling module's internals.
2. **Changing `TildeCore/Contracts/` or `TildeStore/Schema/` is a contract change.** Call it out in the pull request description. The CloudKit schema is additive-only once released.
3. **SwiftData stays in `TildeStore`.** Everything else passes `Sendable` snapshots.
4. **NIO and Citadel types stay in `TildeSSH`**, behind an actor.
5. Only the app target imports concrete implementations; features read services from `@Environment(\.tildeServices)`.

## Code style

- Swift 6 language mode with strict concurrency (`complete`). No new warnings. Avoid `@unchecked Sendable`; if you must use it, explain why in a comment.
- Doc comments (`///`) on all public API.
- SwiftUI views use `TildeColor` / `TildeFont` tokens instead of literals. Machine-readable values (hosts, users, ports, fingerprints) are monospaced.
- Interactive controls need accessibility labels. Check light and dark mode and larger Dynamic Type.
- Keep functions small and names literal. Comments explain why, not what.
- UI copy is short and says what went wrong and how to fix it: *"Connection refused · 10.0.1.12:22. sshd not running or wrong port."*

## Security rules for contributors

- **Never log secrets.** No passwords, passphrases or key material in `print`, `Logger`, errors or crash metadata. Hosts and usernames use `privacy: .private`. `scripts/check-log-secrets.sh` runs in CI.
- **Never put a secret in SwiftData, CloudKit, UserDefaults or the pasteboard.** Secrets live in the Keychain and are referenced by UUID.
- **Test fixtures must be throwaway.** Generate keys for tests; never commit a real key, host, token or `known_hosts` entry.
- **New dependencies need discussion.** Add the package to `scripts/dependency-allowlist.txt`, its license to [`NOTICE`](NOTICE), and explain the need in the pull request. Dependencies are pinned exactly.

## Tests

```sh
cd Packages/TildeKit
swift test                              # everything
swift test --filter TildeFeaturesTests  # one target
```

- Parsers, key codecs, input mapping and anything with byte-exact output need unit tests with fixtures.
- Integration tests that need a real SSH server run in CI behind the `integration` label. To run them locally:

  ```sh
  eval "$(scripts/ci-sshd.sh start)"   # throwaway sshd on 127.0.0.1:2222, key-only
  swift test --filter TildeSSHTests
  scripts/ci-sshd.sh stop
  ```

  Integration tests run only when `TILDE_SSH_INTEGRATION=1` is set, and read their target from these variables
  (printed by `scripts/ci-sshd.sh start`):

  | Variable | Meaning |
  |---|---|
  | `TILDE_SSH_INTEGRATION` | `1` enables the integration tests; without it they skip |
  | `TILDE_TEST_SSH_HOST`, `TILDE_TEST_SSH_PORT`, `TILDE_TEST_SSH_USER` | Where to connect and as whom |
  | `TILDE_TEST_SSH_KEY_ED25519`, `TILDE_TEST_SSH_KEY_ECDSA`, `TILDE_TEST_SSH_KEY_RSA` | Paths to throwaway private keys the server accepts |
  | `TILDE_TEST_SSH_HOST_KEY` | Path to the server's public host key, for host key pinning tests |

  The server only listens on `127.0.0.1` and is built from temporary keys, so nothing here touches your own `~/.ssh`.

- Other checks CI runs: `scripts/validate-metadata.py` (App Store text limits), `scripts/check-dependencies.py`, `scripts/check-log-secrets.sh`.

## Commits and pull requests

- One logical change per pull request. Rebase on `main`; no merge commits.
- Commit messages: a short imperative subject (about 50 characters), then a body that says *why* if it is not obvious. Example: `Pin host keys imported from known_hosts without replacing existing ones`.
- Fill in the pull request template. Screenshots or a short screen recording help for UI changes, with hostnames blurred.
- Update [`CHANGELOG.md`](CHANGELOG.md) under **Unreleased** for anything a user would notice.
- CI must pass: package tests, both app builds, and the repo checks.

## Project files

- **`project.yml`** generates `Tilde.xcodeproj` (`xcodegen generate`). You rarely need it: the `App/` folders are synchronized, and Swift files are discovered by SwiftPM.
- **Entitlements and Info.plists** (`App/iOS`, `App/macOS`) are hand-edited. Keep capabilities minimal; every one is an App Review question.
- **App Store text** lives in `fastlane/metadata/en-US/` and is validated against Apple's limits by `scripts/validate-metadata.py`.
- **Release process** is in [`RELEASING.md`](RELEASING.md).

## License of contributions

Contributions are accepted under the [Apache-2.0 license](LICENSE), as described in section 5 of that license. The name "Tilde" and the icon stay with the project ([`TRADEMARKS.md`](TRADEMARKS.md)).
