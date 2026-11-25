# Releasing Tilde

A checklist for maintainers. Nothing here runs automatically.

## One-time setup

- [ ] Apple Developer Program membership, with the iCloud, Push Notifications and Keychain Sharing capabilities available.
- [ ] Register the identifiers from `Config/Shared.xcconfig` (default prefix `app.tildessh`):
  - App ID `app.tildessh.Tilde` (one ID for iOS, iPadOS and macOS: universal purchase)
  - iCloud container `iCloud.app.tildessh.Tilde`
  - Keychain access group `app.tildessh.shared`
- [ ] Put your Team ID in `Config/Local.xcconfig` (`DEVELOPMENT_TEAM = ...`). It is git-ignored. Decide separately whether the committed `Shared.xcconfig` should carry it for CI signing.
- [ ] Add `TILDE_CLOUDKIT_ENABLED = YES` to `Config/Local.xcconfig` (or pass it to `xcodebuild`) for signed release builds. The committed default is `NO`, so unsigned and fork builds run on a local-only store. It feeds the `TildeCloudKitEnabled` Info.plist key, which the app reads on iOS to decide whether CloudKit may be used (iOS cannot inspect its own entitlements). Verify in the archive's Info.plist that it reads `YES`.
- [ ] Switch `aps-environment` to `production` for release builds (Xcode does this when signing with a distribution profile; verify in the archive's entitlements).
- [ ] Create the App Store Connect record: name, subtitle, categories (Developer Tools, then Utilities), age rating 4+, price Free.
- [ ] App Privacy: **Data Not Collected**. This must match `App/Resources/PrivacyInfo.xcprivacy`.
- [ ] Register the project domain used by `fastlane/metadata/en-US/*_url.txt` and `SECURITY.md`, or change those files.
- [ ] Trademark search before any public asset: USPTO, EUIPO and WIPO for TILDE in classes 9 and 42. Fallback names are noted in `docs/DESIGN.md` section 1.1.

## Every release

1. **Version.** Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Config/Shared.xcconfig`. Move the `CHANGELOG.md` entries from Unreleased to the new version.
2. **CI green** on `main`: package tests, both app builds, repo checks. Run the `sshd integration` job (label a PR with `integration`, or run the workflow manually).
3. **CloudKit schema.** If any `@Model` gained fields since the last release, initialize the development schema (DEBUG-only `initializeCloudKitSchema()` path), then in the CloudKit Console **deploy the development schema to Production before submitting**. A missing deploy means sync silently fails for every user. The schema is additive only after the first deploy.
4. **Export compliance** (see below). Confirm nothing about the cryptography changed.
5. **Metadata.** Edit `fastlane/metadata/en-US/release_notes.txt` and run `scripts/validate-metadata.py`. Keywords must not repeat words from the name or subtitle.
6. **Screenshots.** 6.9" iPhone, 13" iPad and Mac. Hostnames must be fake (`example.com`). Captions are in `docs/DESIGN.md` section 1.2.
7. **Archive** both platforms (Product > Archive, or `xcodebuild archive` with signing). Check the archive's entitlements and that `PrivacyInfo.xcprivacy` is included.
8. **TestFlight** for at least a few days. Test on real devices: Face ID lock, iCloud sync between two devices, a Keychain item syncing, local-network host (Local Network permission prompt), `ssh://` links, background and return.
9. **Submit.** In App Review notes say that Tilde is an SSH client that connects only to servers the user configures, and give a demo server or explain how to test. Free, no sign-in.
10. **Tag** `vX.Y.Z` after approval, and publish a GitHub release with the changelog section.

## Export compliance (encryption)

Tilde implements SSH using standard algorithms from open-source libraries (swift-crypto, swift-nio-ssh, Citadel) and Apple's CryptoKit. `ITSAppUsesNonExemptEncryption` is `YES` in both Info.plists, so App Store Connect asks follow-up questions. Suggested answers, to be confirmed by the maintainer (this is not legal advice):

- *Does your app use encryption?* Yes.
- *Does it qualify for an exemption?* Typically the answer chosen for SSH clients is that the app uses **standard encryption algorithms** and is not limited to Apple's own OS-provided encryption, and that the source code is **publicly available**.
- For the US (BIS), publicly available open-source encryption software is generally eligible for the "publicly available" treatment under the EAR, which requires a **one-time email notification** to BIS and the NSA ENC address with the repository URL (and again if the cryptographic functionality changes). Check current EAR guidance at the time of the first release.
- France: submit the declaration if you distribute there and Apple asks for it.

Record the final answers here and the date they were submitted:

```
Date:
Classification (ECCN / exemption):
BIS notification sent:
```

## After release

- [ ] Watch crash reports in Xcode Organizer. Tilde collects none itself.
- [ ] Triage issues; label regressions for the next patch.
- [ ] Bump dependencies through reviewed Dependabot pull requests, never in a release branch.
