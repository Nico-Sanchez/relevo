// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relevo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Relevo", targets: ["Relevo"]),
    ],
    targets: [
        .target(
            name: "RelevoCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "RelevoUI",
            dependencies: ["RelevoCore"]
        ),
        .executableTarget(
            name: "Relevo",
            dependencies: ["RelevoUI"]
        ),
        .executableTarget(
            name: "Screenshots",
            dependencies: ["RelevoCore", "RelevoUI"]
        ),
        .testTarget(
            name: "RelevoCoreTests",
            dependencies: ["RelevoCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "RelevoUITests",
            dependencies: ["RelevoCore", "RelevoUI"]
        ),
    ]
)
