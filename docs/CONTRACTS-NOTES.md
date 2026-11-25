# Contract notes (Phase 0)

Where the frozen contracts (`TildeCore/Contracts/`, DESIGN.md section 10.2) and the schema (`TildeStore/Schema/`)
differ from, or add to, what the design spec wrote. Changing anything in these two folders needs a PR approved by
WS1 and every consuming workstream.

## Contracts: signatures as written

All types and protocols in section 10.2 exist with the signatures given there. Added to make them usable:

- Public memberwise `init`s for every public struct (Swift does not synthesize public ones). Optional/trailing
  parameters have defaults (e.g. `ConnectionTarget(host:port: = 22, username:)`, `SessionRequest(server:pty:connectTimeout:)`).
- `import Observation` in `AppLocking.swift` (needed for the `Observable` protocol).
- Added conformances (additive, no signature change): `Equatable` on `HostKeyLookup`, `HostKeyDecision`,
  `PromptReason`, `PTYConfig`, `SessionRequest`.
- `PreviewServers`, mocks and `TildeServices.preview` live in `TildeCore/Mocks/` (not a separate testing target) so
  previews in every module can use them.

## Additions that are not in section 10.2

- `TildeServices` (`Contracts/Services.swift`): a plain Sendable struct bundling `SecretStore`, `KeyService`,
  `KnownHostsStore`, `CredentialResolver`, `SessionEngine`, `ReachabilityProbe`, `QuickConnectParsing`,
  `SSHConfigParsing`, `SnippetProviding`. Reason: feature modules cannot import `AppEnvironment` (it lives in the app
  target), so without an agreed injection mechanism each workstream would invent its own. It is injected as
  `@Environment(\.tildeServices)` (declared in `TildeFeatures/Environment/`, defaults to mocks, so previews just work).
  `AppLocking` is `@MainActor` and not Sendable, so the app lock is passed separately (`AppLockGate(lock:)`).
- Mocks beyond the requested list: `FakeKeyService`, `FakeReachabilityProbe`, `FakeQuickConnectParser`,
  `FakeSSHConfigParser`, `FakeAppLock`, `AsyncBroadcaster` (replay-on-subscribe fan-out, handy for `states`).

## Schema (SchemaV1)

- `Server.snippets: [Snippet]?` and `Server.recents: [RecentConnection]?` were added. They are the inverses of
  `Snippet.scopeServer` and `RecentConnection.server`; CloudKit requires every relationship to have an inverse, and the
  section 6.1 table did not list them.
- Models are top-level types (`Server`, `Tag`, ...), not nested in the `VersionedSchema` enum. `TildeSchemaV1.models`
  lists them. When a v2 appears, add `TildeSchemaV2` and move frozen v1 copies into the v1 enum at that point.
- Relationship `@Relationship(inverse:)` is declared on exactly one side of each pair (the "owning" side listed in
  the model files); declaring both sides triggers a macro cycle.
- Store name is `"Tilde"` in every mode, so enabling CloudKit later mirrors the existing local store in place.

## Module graph

Unchanged from section 7.3. Consequence: `TildeDesign` cannot see `ServerEnvironment`, so it has its own `EnvTone`
enum; `EnvTone(_ environment: ServerEnvironment)` is public in `TildeFeatures` and internal in `TildeTerminal`.

## Dependency pins

- Citadel `0.12.1` (== commit `ae8562f`, the revision verified in the design).
- SwiftTerm `1.99.4`. The spec said "2.x", but no 2.x tag exists; 1.99.4 is the newest published release.

## Project generation

The design said "no XcodeGen"; per the Phase 0 brief the project is generated from `project.yml` with `xcodegen`
(committed together with `Tilde.xcodeproj`). `App/*` are synchronized folders and Info.plist / entitlements are
hand-written and referenced by build settings, so owners edit them directly and nobody needs to regenerate the project.

## Building from the command line

SwiftTerm ships a SwiftPM build-tool plugin (`SwiftTermBuildInfoPlugin`). `swift build` / `swift test` run it fine, but
`xcodebuild` refuses to run unvalidated plugins, so every `xcodebuild` call needs
`-skipPackagePluginValidation -skipMacroValidation` (CI and README already pass them). In the Xcode UI, click
"Trust & Enable" once.

## Gotchas for workstream owners

- Swift 6 language mode + strict concurrency is on for every target; the Phase 0 code builds with zero warnings.
- Use `@Entry` for new `EnvironmentValues` keys. For `@MainActor` non-Sendable services (like `AppLocking`) pass them by
  initializer, not through `TildeServices`.
- SwiftData: `ModelContext.insert` takes concrete `@Model` types (no `any PersistentModel` arrays). `@Relationship(inverse:)` on
  one side only. Anything you add to a model needs a default (CloudKit) and, after the first production deploy, schema changes
  are additive only.
- `TildeKeychainAccessGroup` in Info.plist is `$(AppIdentifierPrefix)app.tildessh.shared`; the prefix is empty in unsigned
  builds, so the Keychain store should treat a missing prefix as "no access group".
- Do not run two `swift package resolve` processes at once; the first resolve in a clean checkout clones ~400 MB of
  dependencies (swift-png alone is 175 MB).
