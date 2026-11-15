// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Roost",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Roost", targets: ["Roost"]),
    ],
    targets: [
        // Pure logic (models, persistence, matching, geometry). No AppKit, fully unit-tested.
        .target(name: "RoostCore"),
        // The menu bar app: AppKit, Accessibility and (private) WindowServer/Spaces APIs.
        .executableTarget(
            name: "Roost",
            dependencies: ["RoostCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(name: "RoostCoreTests", dependencies: ["RoostCore"]),
    ]
)
