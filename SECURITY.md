# Security policy

Tilde holds the keys to people's servers, so security reports are taken seriously and handled privately.

## Reporting a vulnerability

**Please do not open a public issue.** Use GitHub's private reporting instead:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability** (a private security advisory).
3. Describe the problem, the affected platform and version, and how to reproduce it.

If you cannot use GitHub advisories, email the maintainers at `security@tildessh.app` (placeholder until the project domain is live; check the repository's Security tab for the current contact).

Please include:

- What an attacker can do, and what they need first (network position, a malicious server, a stolen device).
- Steps or a proof of concept. Use throwaway keys and servers; never send real credentials.
- Your name or handle if you want credit.

## What to expect

- Acknowledgement within **3 working days**.
- An initial assessment within **7 days**, then regular updates until a fix ships.
- A coordinated disclosure: we fix first, release, then publish an advisory. We aim to release within **90 days** of the report and will agree on a date with you if it needs longer.
- Credit in the advisory and changelog unless you prefer otherwise.

There is no bug bounty.

## Supported versions

Security fixes are made for the latest App Store release and for `main`. Older releases are not patched; Tilde updates through the App Store.

## In scope

- Credential or key disclosure (Keychain handling, logs, pasteboard, backups, sync).
- Host key verification bypasses or downgrades (TOFU, changed-key handling, `known_hosts` import).
- Authentication flaws, including key signature and algorithm negotiation.
- Terminal escape-sequence abuse (clipboard writes, title injection, hyperlinks).
- App lock and privacy cover bypasses.
- Memory-safety or parsing bugs in key, `~/.ssh/config`, `known_hosts` or URL handling.
- Vulnerabilities in pinned dependencies that are reachable through Tilde.

## Out of scope

- Attacks that need an already-unlocked, already-compromised device, or a jailbreak.
- Weaknesses in a server's SSH configuration.
- Bugs in Apple's platforms, iCloud or the Keychain themselves (report those to Apple).
- Missing hardening that has no demonstrated impact, and social engineering of maintainers.

## How Tilde handles secrets

A summary of the design, so you know what the intended guarantees are:

- Passwords and private keys live in the Keychain (iCloud Keychain when synced) and are referenced by UUID. They are not stored in SwiftData or CloudKit.
- Server metadata (names, hosts, usernames) syncs through the user's private CloudKit database.
- Host keys are pinned on first use. A changed key aborts the connection before authentication.
- No analytics or third-party SDKs; the privacy manifest declares no tracking and no collected data.

The full threat model is in [`docs/DESIGN.md`](docs/DESIGN.md#64-security-model).

## Dependencies

All dependencies are pinned to exact versions and checked against an allowlist in CI. Citadel currently builds on a maintained fork of `swift-nio-ssh` (`Wellz26/swift-nio-ssh`, pinned at commit `d88989f`, version 0.3.7), which is the SSH transport Tilde runs on. We review the fork's diff against upstream `apple/swift-nio-ssh` and the Citadel changes on every bump before updating the pin. If you find a vulnerability in an upstream package, please report it upstream as well.
