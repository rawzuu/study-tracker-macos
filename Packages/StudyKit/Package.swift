// swift-tools-version: 6.2
import PackageDescription

// Moduly aplikace. Core nemá žádné závislosti – drží datový model sdílený s webem.
// Jediná externí závislost je GRDB (lokální úložiště), připnutá na přesnou verzi.
let package = Package(
    name: "StudyKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Engine", targets: ["Engine"]),
        .library(name: "Networking", targets: ["Networking"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Sync", targets: ["Sync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Engine", dependencies: ["Core"]),
        .target(name: "Networking"),
        .target(
            name: "Persistence",
            dependencies: ["Core", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "Sync", dependencies: ["Core", "Networking", "Persistence"]),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "EngineTests", dependencies: ["Engine"]),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking"]),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "SyncTests", dependencies: ["Sync"]),
    ]
)
