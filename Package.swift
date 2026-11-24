// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relevo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Relevo", targets: ["Relevo"]),
        .executable(name: "RelevoCode", targets: ["RelevoCodeApp"]),
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
        .target(name: "RelevoCI"),
        .testTarget(
            name: "RelevoCITests",
            dependencies: ["RelevoCI"]
        ),
        .target(name: "RelevoCode"),
        .executableTarget(
            name: "RelevoCodeApp",
            dependencies: ["RelevoCode", "RelevoCI"]
        ),
        .testTarget(
            name: "RelevoCodeTests",
            dependencies: ["RelevoCode", "RelevoCodeApp", "RelevoCI"]
        ),
    ]
)
