// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeAccounts",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeAccounts", targets: ["ClaudeAccounts"]),
    ],
    targets: [
        .target(
            name: "ClaudeAccountsCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ClaudeAccounts",
            dependencies: ["ClaudeAccountsCore"]
        ),
        .testTarget(
            name: "ClaudeAccountsCoreTests",
            dependencies: ["ClaudeAccountsCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
