// swift-tools-version: 6.2
import PackageDescription

// Moduly aplikace. Core nemá žádné závislosti – drží datový model sdílený s webem.
let package = Package(
    name: "StudyKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Core", targets: ["Core"]),
    ],
    targets: [
        .target(name: "Core"),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
