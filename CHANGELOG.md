# Changelog

All notable changes to Tilde are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/) (the App Store build number is tracked separately in `Config/Shared.xcconfig`).

## [Unreleased]

## [1.0.0] - 2026-11-26

First release.

### Added

- Servers with groups, tags, favorites, environments (PROD is color-coded), search and live reachability; Quick Connect for `user@host:port` and `ssh://` links.
- Terminal on SwiftTerm: xterm-256color and truecolor, scrollback, find, three themes, SF Mono and Menlo, adjustable font size, multi-line paste confirmation.
- SSH key bar for iPhone and iPad with sticky and locked modifiers, flick alternates, an arrow joystick, pages and an editor; Option-as-Meta and a slim strip for hardware keyboards.
- Tabs, multiple windows and a full menu bar on iPad and Mac.
- Key manager: generate Ed25519 / ECDSA / RSA, import OpenSSH and PEM keys (including encrypted ones), share or install the public key, export the private key behind device authentication.
- Host key verification with a hard stop on a changed key, and a Known Hosts list in Settings with fingerprints, status, search and Forget.
- Snippets with placeholders, jump host (single hop), auto-reconnect with backoff, tmux attach.
- iCloud sync for server metadata (CloudKit) with iCloud Keychain for secrets; onboarding explains when sync is off.
- App lock with Face ID / Touch ID, privacy cover, clipboard expiry.

### Changed

- The terminal background now follows the theme on iOS and iPadOS (it rendered black before).

### Notes

- A bundled Nerd Font is planned for 1.1; SF Mono stays the default.

### Also included

- Project skeleton: iOS/iPadOS and macOS app targets, the `TildeKit` package with its seven modules, frozen module contracts and mocks, CI.
- Mac menu bar (File, Edit, View, Session, Window) driven by focused scene values, with tab shortcuts on ⌘1 to ⌘9.
- Import from `~/.ssh/config` with a preview, duplicate detection, single-hop `ProxyJump` and key file import prompts.
- Import from `known_hosts` (plain and `[host]:port` entries; hashed entries are skipped and counted). Existing pins are never overwritten.
- Secure Keyboard Entry toggle in the Session menu.
- App icon with a tinted variant for iOS, and App Store listing text for en-US.
- Open-source repository documents: README, CONTRIBUTING, SECURITY, TRADEMARKS, CODE_OF_CONDUCT, NOTICE.

[Unreleased]: https://github.com/ahmadrezaei/tilde-ssh/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ahmadrezaei/tilde-ssh/releases/tag/v1.0.0
