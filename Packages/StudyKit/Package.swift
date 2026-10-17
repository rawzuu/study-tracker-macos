// swift-tools-version: 6.2
import PackageDescription

// Moduly aplikace. Core nemá žádné závislosti – drží datový model sdílený s webem.
let package = Package(
    name: "StudyKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Core", targets: ["Core"]),
        .library(name: "Networking", targets: ["Networking"]),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Networking"),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking"]),
    ]
)
