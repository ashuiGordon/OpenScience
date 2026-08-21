// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OpenScienceDesktop",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OpenScienceCore", targets: ["OpenScienceCore"]),
        .library(name: "OpenScienceDesktopLogic", targets: ["OpenScienceDesktopLogic"]),
        .executable(name: "OpenScienceDesktop", targets: ["OpenScienceDesktop"]),
    ],
    targets: [
        .target(
            name: "OpenScienceCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "OpenScienceDesktop",
            dependencies: ["OpenScienceCore", "OpenScienceDesktopLogic"],
            path: "Sources/OpenScienceDesktop",
            exclude: ["Logic"]
        ),
        .target(
            name: "OpenScienceDesktopLogic",
            dependencies: ["OpenScienceCore"],
            path: "Sources/OpenScienceDesktop/Logic"
        ),
        .testTarget(
            name: "OpenScienceCoreTests",
            dependencies: ["OpenScienceCore"]
        ),
        .testTarget(
            name: "OpenScienceDesktopTests",
            dependencies: ["OpenScienceCore", "OpenScienceDesktopLogic"],
            path: "Tests/OpenScienceDesktopTests"
        ),
    ]
)
