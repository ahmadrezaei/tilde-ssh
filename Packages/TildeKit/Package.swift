// swift-tools-version: 6.2
//
// TildeKit: all of Tilde's logic lives here so `swift build` / `swift test` work headless.
// Module dependency graph (an arrow means "depends on"), see docs/DESIGN.md section 7.3:
//
//   TildeFeatures -> TildeTerminal, TildeSSH, TildeSecurity, TildeStore, TildeDesign, TildeCore
//   TildeTerminal -> TildeDesign, TildeCore, SwiftTerm
//   TildeSSH      -> TildeCore, Citadel
//   TildeSecurity -> TildeCore, TildeDesign, CTildeBcrypt (vendored OpenBSD bcrypt_pbkdf), Citadel
//   TildeStore    -> TildeCore
//   TildeDesign   -> (none)
//   TildeCore     -> (none)

import PackageDescription

let package = Package(
    name: "TildeKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(name: "TildeCore", targets: ["TildeCore"]),
        .library(name: "TildeStore", targets: ["TildeStore"]),
        .library(name: "TildeSecurity", targets: ["TildeSecurity"]),
        .library(name: "TildeSSH", targets: ["TildeSSH"]),
        .library(name: "TildeTerminal", targets: ["TildeTerminal"]),
        .library(name: "TildeDesign", targets: ["TildeDesign"]),
        .library(name: "TildeFeatures", targets: ["TildeFeatures"]),
    ],
    dependencies: [
        // Pinned exactly. Citadel 0.12.1 == commit ae8562f (the revision verified in the design spec).
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.4"),
    ],
    targets: [
        // MARK: Leaves
        .target(name: "TildeCore"),
        .target(name: "TildeDesign"),
        // Vendored OpenBSD Blowfish + bcrypt_pbkdf (needed to decrypt `openssh-key-v1` keys). See Sources/CTildeBcrypt.
        .target(name: "CTildeBcrypt"),

        // MARK: Mid-level
        .target(name: "TildeStore", dependencies: ["TildeCore"]),
        .target(
            name: "TildeSecurity",
            dependencies: [
                "TildeCore",
                "TildeDesign",
                "CTildeBcrypt",
                .product(name: "Citadel", package: "Citadel"),
            ]
        ),
        .target(
            name: "TildeSSH",
            dependencies: [
                "TildeCore",
                .product(name: "Citadel", package: "Citadel"),
            ]
        ),
        .target(
            name: "TildeTerminal",
            dependencies: [
                "TildeDesign",
                "TildeCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),

        // MARK: Top
        .target(
            name: "TildeFeatures",
            dependencies: [
                "TildeTerminal",
                "TildeSSH",
                "TildeSecurity",
                "TildeStore",
                "TildeDesign",
                "TildeCore",
            ]
        ),

        // MARK: Tests (one folder per module)
        .testTarget(name: "TildeCoreTests", dependencies: ["TildeCore"]),
        .testTarget(name: "TildeStoreTests", dependencies: ["TildeStore", "TildeCore"]),
        .testTarget(
            name: "TildeSecurityTests",
            dependencies: [
                "TildeSecurity",
                "TildeCore",
                // Interop checks: Citadel (used for auth) must accept the keys this module writes.
                .product(name: "Citadel", package: "Citadel"),
            ],
            exclude: ["generate-fixtures.sh"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "TildeSSHTests", dependencies: ["TildeSSH", "TildeCore"]),
        .testTarget(name: "TildeTerminalTests", dependencies: ["TildeTerminal", "TildeCore"]),
        .testTarget(name: "TildeFeaturesTests", dependencies: ["TildeFeatures", "TildeCore", "TildeStore", "TildeSecurity", "TildeDesign"]),
    ]
)
