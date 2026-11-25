# Changelog

All notable changes to Tilde are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/) (the App Store build number is tracked separately in `Config/Shared.xcconfig`).

## [Unreleased]

### Added

- Project skeleton: iOS/iPadOS and macOS app targets, the `TildeKit` package with its seven modules, frozen module contracts and mocks, CI.
- Mac menu bar (File, Edit, View, Session, Window) driven by focused scene values, with tab shortcuts on ⌘1 to ⌘9.
- Import from `~/.ssh/config` with a preview, duplicate detection, single-hop `ProxyJump` and key file import prompts.
- Import from `known_hosts` (plain and `[host]:port` entries; hashed entries are skipped and counted). Existing pins are never overwritten.
- Secure Keyboard Entry toggle in the Session menu.
- App icon with a tinted variant for iOS, and App Store listing text for en-US.
- Open-source repository documents: README, CONTRIBUTING, SECURITY, TRADEMARKS, CODE_OF_CONDUCT, NOTICE.

[Unreleased]: https://github.com/ahmadrezaei/tilde-ssh/commits/main
