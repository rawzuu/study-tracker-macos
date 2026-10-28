// swift-tools-version: 6.2
import PackageDescription

// Moduly aplikace. Core nemá žádné závislosti – drží datový model sdílený s webem.
// Core → Engine (výpočty) · Networking (GitHub) · Persistence (Mac) → Sync → AppModel → Features (+ DesignSystem)
// WidgetData (souhrn pro widgety, jen Foundation) → AppModel i WidgetUI (vzhled widgetů, bez dat a sítě)
// Focus (Soustředění: pravidla blokování a měření, Engine + WidgetData) → FocusStore (databáze ve sdíleném kontejneru)
//   – obojí používá aplikace i Strážce (pomocník na pozadí); FocusGuard je Strážce sám (AppKit, blokovací obrazovka).
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
        .library(name: "AppModel", targets: ["AppModel"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "Features", targets: ["Features"]),
        .library(name: "WidgetData", targets: ["WidgetData"]),
        .library(name: "WidgetUI", targets: ["WidgetUI"]),
        .library(name: "Focus", targets: ["Focus"]),
        .library(name: "FocusStore", targets: ["FocusStore"]),
        .library(name: "FocusGuard", targets: ["FocusGuard"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "Core"),
        .target(name: "Engine", dependencies: ["Core"]),
        .target(name: "Networking", dependencies: ["Core"]),
        .target(
            name: "Persistence",
            dependencies: ["Core", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "Sync", dependencies: ["Core", "Networking", "Persistence"]),
        .target(name: "AppModel", dependencies: ["Core", "Engine", "Networking", "Persistence", "Sync", "WidgetData", "Focus", "FocusStore"]),
        .target(name: "DesignSystem"),
        .target(name: "WidgetData"),
        .target(name: "WidgetUI", dependencies: ["WidgetData", "DesignSystem"]),
        .target(name: "Focus", dependencies: ["Engine", "WidgetData"]),
        .target(name: "FocusStore", dependencies: ["Focus", "Engine", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "FocusGuard", dependencies: ["Focus", "FocusStore", "Engine", "WidgetData", "DesignSystem"]),
        .target(name: "Features", dependencies: ["Core", "Engine", "Networking", "Sync", "AppModel", "DesignSystem", "Focus", "FocusStore"]),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "EngineTests",
            dependencies: ["Engine", "Core"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking"]),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "SyncTests", dependencies: ["Sync"]),
        .testTarget(name: "AppModelTests", dependencies: ["AppModel", "Core", "Engine", "Networking", "Persistence", "Sync"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Features", "Core", "Engine", "AppModel", "DesignSystem"]),
        .testTarget(name: "FocusTests", dependencies: ["Focus", "Engine", "WidgetData"]),
        .testTarget(name: "FocusStoreTests", dependencies: ["FocusStore", "Focus", "Engine"]),
        .testTarget(name: "FocusGuardTests", dependencies: ["FocusGuard", "FocusStore", "Focus", "Engine", "WidgetData"]),
        .testTarget(name: "WidgetTests", dependencies: ["WidgetData", "WidgetUI", "AppModel", "Core", "Engine", "Persistence", "DesignSystem"]),
    ]
)
