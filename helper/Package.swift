// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LRCScopes",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "LRCScopes", targets: ["LRCScopes"]),
        .library(name: "ScopesCore", targets: ["ScopesCore"]),
    ],
    targets: [
        // Pure, UI-free scope math. Everything in here is unit tested.
        .target(name: "ScopesCore"),
        // The AppKit companion app that Lightroom's plug-in launches.
        .executableTarget(
            name: "LRCScopes",
            dependencies: ["ScopesCore"]
        ),
        .testTarget(
            name: "ScopesCoreTests",
            dependencies: ["ScopesCore"]
        ),
    ]
)
