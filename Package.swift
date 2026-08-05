// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "roost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RoostCore", targets: ["RoostCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.15.0"),
    ],
    targets: [
        // All the logic without a single AppKit import: that is why `swift test`
        // runs in seconds and needs neither Xcode nor a screen.
        .target(name: "RoostCore"),
        .testTarget(name: "RoostCoreTests", dependencies: ["RoostCore"]),

        // The app itself. Built through SPM rather than Xcode: for SwiftTerm's
        // Metal shader Xcode 26 demands a separate Metal Toolchain, which
        // `swift build` never asks for. The bundle is assembled by
        // tool/bundle.sh.
        .executableTarget(
            name: "Roost",
            dependencies: [
                "RoostCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ]
)
