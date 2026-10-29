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
        .target(
            name: "ClaudeAccountsUI",
            dependencies: ["ClaudeAccountsCore"]
        ),
        .executableTarget(
            name: "ClaudeAccounts",
            dependencies: ["ClaudeAccountsUI"]
        ),
        .executableTarget(
            name: "Screenshots",
            dependencies: ["ClaudeAccountsCore", "ClaudeAccountsUI"]
        ),
        .testTarget(
            name: "ClaudeAccountsCoreTests",
            dependencies: ["ClaudeAccountsCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
