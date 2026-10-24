// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpaceNamer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SpaceNamer", targets: ["SpaceNamer"]),
        // Installed as Contents/Helpers/spacenamer inside the app.
        .executable(name: "SpaceNamerAgent", targets: ["SpaceNamerAgent"]),
    ],
    targets: [
        // Thin C shim over the read-only window-server Spaces API and the synthetic Dock swipe.
        .target(
            name: "CGSBridge",
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("ApplicationServices")]
        ),
        // Everything that does not need a UI: models, parsing, persistence, switching.
        .target(
            name: "SpaceNamerCore",
            dependencies: ["CGSBridge"]
        ),
        .executableTarget(
            name: "SpaceNamer",
            dependencies: ["SpaceNamerCore", "CGSBridge"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]
        ),
        // The command-line helper for agents: Claude Code hooks, the MCP server, scripts.
        .executableTarget(
            name: "SpaceNamerAgent",
            dependencies: ["SpaceNamerCore"]
        ),
        .testTarget(
            name: "SpaceNamerCoreTests",
            dependencies: ["SpaceNamerCore"]
        ),
    ]
)
