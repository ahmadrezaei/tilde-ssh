# Trademarks and branding

The source code of Tilde is licensed under [Apache-2.0](LICENSE). That license covers the code, and **section 6 of it explicitly does not grant permission to use the project's names, logos or trade dress**. This page says what that means in practice.

## What is reserved

- The name **Tilde**, including "Tilde – SSH Client & Terminal" and `tilde-ssh`.
- The **app icon** (the mint tilde ending in a block cursor, `design/icon.svg`) and the App Store screenshots and marketing copy.

These are not registered trademarks at the time of writing; the project reserves them as common-law marks, and may register them later.

## What you can do

- **Fork and modify the code** for any purpose, as the license allows.
- **Build and run it yourself**, on your own devices, with your own Apple developer account.
- **Say what it is:** "based on Tilde", "a fork of Tilde", "compatible with Tilde" are fine, as long as it is clear your project is not the official app.
- **Link to the project** and use the name in articles, reviews and tutorials.
- **Contribute** changes upstream. Contributions do not transfer the name.

## What you should not do

- **Publish a fork to the App Store, TestFlight or any other store under the name "Tilde"** or a name that could be confused with it, or with the official icon. Choose your own name and icon.
- Imply that a fork, product or service is made, endorsed or supported by the Tilde project.
- Register the name, or a confusingly similar one, as a trademark, domain or store listing.

## Making a fork

Change these in one place, [`Config/Shared.xcconfig`](Config/Shared.xcconfig), and replace the icon and display name:

- `TILDE_BUNDLE_PREFIX` / `TILDE_BUNDLE_ID` (bundle identifier, CloudKit container, Keychain group)
- `DEVELOPMENT_TEAM`
- `CFBundleDisplayName` in `App/iOS/Info.plist` and `App/macOS/Info.plist`
- `App/Resources/Assets.xcassets/AppIcon.appiconset` and `design/icon.svg`
- `fastlane/metadata/`

Keep the `LICENSE` and `NOTICE` files, and add your own copyright line for your changes.

## Third-party names

Other product names mentioned in this repository (Apple, iCloud, iPhone, iPad, Mac, Face ID, Touch ID, App Store, GitHub, OpenSSH, and others) belong to their owners. Tilde is an independent project and is not affiliated with or endorsed by them.

## Questions

Open a discussion or an issue if you are unsure whether a use is fine. When in doubt, ask first.
